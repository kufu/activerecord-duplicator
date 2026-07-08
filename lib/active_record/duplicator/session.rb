# frozen_string_literal: true

module ActiveRecord
  class Duplicator
    # One-shot execution context for a duplication run.
    #
    # A Session owns the record id map (old_id -> new_id, per class) and
    # exposes the API a handler needs: no_duplicate / store_duplicate_id /
    # fetch_duplicate_id / bulk_insert / attributes_for.
    #
    # Users normally do not instantiate Session directly; a fresh Session is
    # created by Duplicator#duplicate for every run, so state does not leak
    # across runs. Duplicator#duplicate yields the Session to its block so
    # callers can no_duplicate / store_duplicate_id before the run starts.
    #
    # Composite primary keys (Rails 7.1+ `self.primary_key = [:a, :b]`) are
    # supported. An id is a scalar for a single-column primary key and an
    # Array for a composite one; the shape simply mirrors what
    # `record.class.primary_key` reports.
    class Session
      DEFAULT_BATCH_SIZE = 1000
      private_constant :DEFAULT_BATCH_SIZE

      # @rbs @record_id_map: Hash[Class, Hash[untyped, untyped]]
      # @rbs @handlers: Hash[Class, Proc]
      # @rbs @user_handlers: Hash[Class, Proc]
      # @rbs @no_duplicate_classes: Set[Class]

      #: (?handlers: Hash[Class, Proc], ?no_duplicate_classes: Set[Class]) -> void
      def initialize(handlers: {}, no_duplicate_classes: Set.new)
        @record_id_map = Hash.new { |hash, klass| hash[klass] = {} }
        @handlers = handlers
        @user_handlers = {}
        # dup so that Session#no_duplicate_class additions never leak back to the
        # Duplicator-level set shared across every run.
        @no_duplicate_classes = no_duplicate_classes.dup
      end

      # Register a handler that overrides Duplicator#on for the current session
      # only. Useful when a single duplication run needs a special copy of a
      # model that the shared Duplicator config should not know about.
      #
      # Raises DuplicateHandlerError when the same class is registered twice
      # via Session#on in the same session. Overriding a class that also has a
      # Duplicator-level handler is intentional and does not raise.
      #: (Class) { (HandlerApi, Class, untyped) -> void } -> void
      def on(klass, &block)
        raise DuplicateHandlerError, "handler for #{klass} is already overridden in this session" if @user_handlers.key?(klass)

        @user_handlers[klass] = block
      end

      # Declare that the given records must not be duplicated: their new_id
      # is set equal to their old_id, so any record duplicated later that
      # references them will keep pointing at the same rows.
      #: (*ActiveRecord::Base) -> void
      def no_duplicate(*records)
        records.each do |record|
          id = current_id(record)
          store_duplicate_id(record.class, old_id: id, new_id: id)
        end
      end

      # Declare that the given ids of the given class must not be duplicated,
      # without loading the records. Equivalent to calling no_duplicate on each
      # record but avoids the database round-trip when the ids are already
      # known. Each id should have the same shape as the class's primary key
      # (scalar for a single-column pk, Array for a composite pk).
      #: (Class, *untyped) -> void
      def no_duplicate_id(klass, *ids)
        ids.each { |id| store_duplicate_id(klass, old_id: id, new_id: id) }
      end

      # Class-wide equivalent of no_duplicate: it is exactly as if every record
      # of each given class had been passed to no_duplicate. Handlers still fire
      # (matching the no_duplicate case where a handler for the class is invoked
      # with a Relation that happens to contain no_duplicate records); the
      # default bulk_insert path becomes a no-op, and fetch_duplicate_id echoes
      # the queried old_id back unchanged.
      #
      # Use when the target database is expected to already hold every
      # referenced row (shared lookup tables, tenant-wide catalogs, etc.), so
      # per-record no_duplicate would only differ from this in cost, not effect.
      #: (*Class) -> void
      def no_duplicate_class(*klasses)
        @no_duplicate_classes.merge(klasses)
      end

      # Record a mapping from an old_id to a new_id. Called automatically from
      # bulk_insert; called explicitly by user code (or a handler) when new
      # records are produced outside of the default duplication path.
      #
      # For a single-column primary key pass a scalar; for a composite primary
      # key pass an Array matching the shape of the class's primary_key.
      #
      # Raises InvalidRecordIdError when the same old_id is already mapped to
      # a different new_id.
      #: (Class, old_id: untyped, new_id: untyped) -> void
      def store_duplicate_id(klass, old_id:, new_id:)
        map = @record_id_map[klass]

        if !map.key?(old_id)
          map[old_id] = new_id
        elsif map[old_id] != new_id
          raise InvalidRecordIdError,
            "#{klass} old_id=#{old_id.inspect} is already mapped to " \
            "#{map[old_id].inspect}, cannot overwrite with #{new_id.inspect}"
        end
      end

      # Look up a new_id by (klass, old_id). Returns a scalar for a
      # single-column pk and an Array for a composite pk.
      #
      # Raises MissingNewIdError when no mapping exists. This usually means a
      # belongs_to parent has not been duplicated yet; place it earlier in the
      # associations tree, or call no_duplicate / no_duplicate_id explicitly.
      #: (Class, old_id: untyped) -> untyped
      def fetch_duplicate_id(klass, old_id:)
        return old_id if @no_duplicate_classes.include?(klass)

        @record_id_map[klass].fetch(old_id) do
          raise MissingNewIdError, "no duplicate id registered for #{klass}##{old_id.inspect}"
        end
      end

      # Bulk-insert copies of the given records into klass, omitting any that
      # are already present in the id map. Handlers can reuse this via HandlerApi
      # to defer a subset of records to the default duplication path.
      #
      # When klass has been passed to no_duplicate_class the call is a no-op that
      # never touches the DB: it is equivalent to having pre-registered every
      # incoming record via no_duplicate, only without the per-record enumeration.
      #: (Class, untyped, ?batch_size: Integer, ?cursor: untyped) -> void
      def bulk_insert(klass, records, batch_size: DEFAULT_BATCH_SIZE, cursor: nil)
        return if @no_duplicate_classes.include?(klass)

        ensure_insert_returning_supported!(klass)

        batches = enumerate_batches(records, batch_size:, cursor:)

        batches.each do |batch|
          old_records = batch.to_a
          old_records.reject! { |r| @record_id_map[klass].key?(current_id(r)) }
          next if old_records.empty?

          rows = old_records.map { |r| attributes_for(klass, r) }
          inserted = klass.insert_all!(rows)

          inserted.to_a.each.with_index do |returned_row, i|
            new_id = extract_id_from_row(klass, returned_row)
            old_id = current_id(old_records[i])
            store_duplicate_id(klass, old_id:, new_id:)
          end
        end
      end

      # Build the attribute Hash for a single record, ready to be handed to
      # insert_all!. Timestamps (as reported by
      # klass.all_timestamp_attributes_in_model, which covers created_at /
      # updated_at / created_on / updated_on), auto-generated primary key
      # columns, and every belongs_to foreign key column are stripped; each
      # belongs_to foreign key is then re-populated from the id map so it
      # points to the new parent. Non-auto columns of a composite primary key
      # (e.g. tenant_id) are carried over from the source record unchanged.
      #: (Class, ActiveRecord::Base) -> Hash[String, untyped]
      def attributes_for(klass, old_record)
        belongs_to = klass.reflect_on_all_associations(:belongs_to)
        fk_columns = belongs_to.flat_map { |r| Array.wrap(r.foreign_key) }
        ignored = auto_generated_pk_columns(klass) + klass.all_timestamp_attributes_in_model + fk_columns
        attrs = old_record.attributes.except(*ignored)

        belongs_to.each { |reflection| assign_foreign_key(attrs, reflection, old_record) }

        attrs
      end

      # Run the duplication inside a transaction and return the freshly loaded
      # root record. Normally invoked by Duplicator#duplicate.
      #
      # transaction_options is passed through verbatim to
      # `root_record.transaction`, so callers can request `requires_new: true`
      # / `joinable: false` / `isolation: :serializable` etc. as fits the
      # surrounding call site. It defaults to `{}`, i.e. plain
      # `transaction do ... end` behaviour.
      #: (ActiveRecord::Base, ?associations: untyped, ?transaction_options: Hash[Symbol, untyped]) -> ActiveRecord::Base
      def run(root_record, associations: [], transaction_options: {})
        root_record.transaction(**transaction_options) do
          duplicate_records(root_record.class, [root_record])

          AssociationTraversal.new(root_record, associations).each do |relation|
            duplicate_records(relation.klass, relation)
          end

          new_id = fetch_duplicate_id(root_record.class, old_id: current_id(root_record))
          root_record.class.find(new_id)
        end
      end

      private

      # Dispatch to a handler (or the default bulk_insert path) for `klass`.
      # All records in `relation_or_records` are assumed to be of `klass`; the
      # caller is responsible for splitting mixed inputs (e.g. STI subclasses)
      # into per-class Relations and passing the matching class in.
      #
      # no_duplicate_class does NOT short-circuit here: handlers must still fire
      # (mirroring the per-record no_duplicate case), and the class-wide exclusion
      # is applied inside bulk_insert instead.
      #: (Class, untyped) -> void
      def duplicate_records(klass, relation_or_records)
        handler = resolve_handler(klass)

        if handler
          handler.call(HandlerApi.new(self), klass, relation_or_records)
        else
          bulk_insert(klass, relation_or_records)
        end
      end

      # Session-local handlers (Session#on) take precedence over any
      # Duplicator-level handler registered for the exact same class.
      #: (Class) -> Proc?
      def resolve_handler(klass)
        @user_handlers[klass] || @handlers[klass]
      end

      #: (untyped, batch_size: Integer, cursor: untyped) -> untyped
      def enumerate_batches(records, batch_size:, cursor:)
        if records.respond_to?(:in_batches) && cursor
          records.in_batches(of: batch_size, cursor:)
        elsif records.respond_to?(:find_in_batches)
          records.find_in_batches(batch_size:)
        else
          records.each_slice(batch_size)
        end
      end

      # Return the id of the given record shaped like the class's primary_key:
      # a scalar for a single-column pk, an Array for a composite pk.
      #: (ActiveRecord::Base) -> untyped
      def current_id(record)
        pk = record.class.primary_key
        if pk.is_a?(Array)
          pk.map { |c| record[c] }
        else
          record[pk]
        end
      end

      # Extract the primary key value from a row returned by insert_all!.
      # Scalar for single-column pk, Array for composite pk.
      #: (Class, Hash[String, untyped]) -> untyped
      def extract_id_from_row(klass, row)
        pk = klass.primary_key
        if pk.is_a?(Array)
          pk.map { |c| row[c.to_s] }
        else
          row[pk.to_s]
        end
      end

      #: (Hash[String, untyped], untyped, ActiveRecord::Base) -> void
      def assign_foreign_key(attrs, reflection, old_record)
        fk = reflection.foreign_key

        if fk.is_a?(Array)
          old_values = fk.map { |c| old_record[c] }
          if old_values.all?(&:nil?)
            fk.each { |c| attrs[c] = nil }
          else
            new_values = fetch_duplicate_id(reflection.klass, old_id: old_values)
            fk.zip(new_values).each { |c, v| attrs[c] = v }
          end
        else
          old_value = old_record[fk]
          attrs[fk] = old_value.nil? ? nil : fetch_duplicate_id(reflection.klass, old_id: old_value)
        end
      end

      # Primary key columns whose values are filled in by the database (e.g. a
      # bigserial `id`, a SQLite INTEGER PRIMARY KEY / ROWID alias, a column
      # with a `default_function` such as `gen_random_uuid()`). These must be
      # stripped from the attributes before calling insert_all! so the DB can
      # assign fresh values. Composite pk columns without a default (e.g.
      # tenant_id) are kept.
      #: (Class) -> Array[String]
      def auto_generated_pk_columns(klass)
        Array.wrap(klass.primary_key).select do |key|
          column = klass.column_for_attribute(key)
          column.auto_populated?
        end
      end

      # Guard against adapters that cannot return inserted primary keys.
      # The default path relies on `insert_all!(...)` echoing back the pk of
      # every inserted row so the id map can be populated in one round trip;
      # adapters that do not support RETURNING silently return an empty
      # inserted-row set and would leave the map incomplete.
      #: (Class) -> void
      def ensure_insert_returning_supported!(klass)
        connection = klass.connection
        return if connection.supports_insert_returning?

        raise UnsupportedAdapterError,
          "#{connection.adapter_name} does not support insert with RETURNING. " \
          "activerecord-duplicator requires an adapter whose " \
          "`supports_insert_returning?` returns true (e.g. PostgreSQL, or " \
          "SQLite >= 3.35). Register a custom handler with `on(#{klass})` " \
          "if you need to duplicate #{klass} on this adapter."
      end
    end
  end
end
