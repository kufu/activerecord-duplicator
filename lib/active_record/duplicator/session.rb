# frozen_string_literal: true

module ActiveRecord
  class Duplicator
    # One-shot execution context for a duplication run.
    #
    # A Session owns the record id map (old_id -> new_id, per class) and
    # exposes the API a handler needs: mark_skip / store_new_id / fetch_new_id
    # / bulk_insert / attributes_for.
    #
    # Users normally do not instantiate Session directly; a fresh Session is
    # created by Duplicator#duplicate for every run, so state does not leak
    # across runs. Duplicator#duplicate yields the Session to its block so
    # callers can mark_skip / store_new_id before the run starts.
    #
    # Composite primary keys (Rails 7.1+ `self.primary_key = [:a, :b]`) are
    # supported. An id is a scalar for a single-column primary key and an
    # Array for a composite one; the shape simply mirrors what
    # `record.class.primary_key` reports.
    class Session
      DEFAULT_BATCH_SIZE = 1000
      TIMESTAMP_COLUMNS = %w[created_at updated_at].freeze
      private_constant :DEFAULT_BATCH_SIZE, :TIMESTAMP_COLUMNS

      # @rbs @record_id_map: Hash[Class, Hash[untyped, untyped]]
      # @rbs @handlers: Hash[Class, Proc]
      # @rbs @user_handlers: Hash[Class, Proc]

      #: (?handlers: Hash[Class, Proc]) -> void
      def initialize(handlers: {})
        @record_id_map = Hash.new { |hash, klass| hash[klass] = {} }
        @handlers = handlers
        @user_handlers = {}
        @handlers_cache = {}
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
        @handlers_cache.clear

        if @user_handlers.key?(klass)
          raise DuplicateHandlerError, "handler for #{klass} is already overridden in this session"
        end

        @user_handlers[klass] = block
      end

      # Declare that the given records must not be duplicated: their new_id
      # is set equal to their old_id, so any record duplicated later that
      # references them will keep pointing at the same rows.
      #: (*ActiveRecord::Base) -> void
      def mark_skip(*records)
        records.each do |record|
          id = current_id(record)
          store_new_id(record.class, old_id: id, new_id: id)
        end
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
      def store_new_id(klass, old_id:, new_id:)
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
      # associations tree or register/skip it explicitly.
      #: (Class, old_id: untyped) -> untyped
      def fetch_new_id(klass, old_id:)
        @record_id_map[klass].fetch(old_id) do
          raise MissingNewIdError, "no new_id registered for #{klass}##{old_id}"
        end
      end

      # Bulk-insert copies of the given records into klass, skipping any that
      # are already present in the id map. Handlers can reuse this via HandlerApi
      # to defer a subset of records to the default duplication path.
      #: (Class, untyped, ?batch_size: Integer, ?cursor: untyped) -> void
      def bulk_insert(klass, records, batch_size: DEFAULT_BATCH_SIZE, cursor: nil)
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
            store_new_id(klass, old_id:, new_id:)
          end
        end
      end

      # Build the attribute Hash for a single record, ready to be handed to
      # insert_all!. Timestamps, auto-generated primary key columns, and every
      # belongs_to foreign key column are stripped; each belongs_to foreign
      # key is then re-populated from the id map so it points to the new
      # parent. Non-auto columns of a composite primary key (e.g. tenant_id)
      # are carried over from the source record unchanged.
      #: (Class, ActiveRecord::Base) -> Hash[String, untyped]
      def attributes_for(klass, old_record)
        belongs_to = klass.reflect_on_all_associations(:belongs_to)
        fk_columns = belongs_to.flat_map { |r| Array.wrap(r.foreign_key) }
        ignored = auto_generated_pk_columns(klass) + TIMESTAMP_COLUMNS + fk_columns
        attrs = old_record.attributes.except(*ignored)

        belongs_to.each { |reflection| assign_foreign_key(attrs, reflection, old_record) }

        attrs
      end

      # Run the duplication inside a new, non-joinable transaction and return
      # the freshly loaded root record. Normally invoked by Duplicator#duplicate.
      #: (ActiveRecord::Base, ?associations: untyped) -> ActiveRecord::Base
      def run(root_record, associations: [])
        root_record.transaction(requires_new: true, joinable: false) do
          duplicate_records([root_record])

          AssociationTraversal.new(root_record, associations).each do |relation|
            duplicate_records(relation)
          end

          new_id = fetch_new_id(root_record.class, old_id: current_id(root_record))
          root_record.class.find(new_id)
        end
      end

      private

      #: (untyped) -> void
      def duplicate_records(relation_or_records)
        # Group by the real class of each record so a handler registered on an
        # STI subclass fires only for records of that subclass. For non-STI
        # models every record shares the given `klass`, so a single group is
        # produced.
        groups = Hash.new { |hash, k| hash[k] = [] }
        relation_or_records.each { |record| groups[record.class] << record }

        groups.each do |real_class, records|
          handler = cache_or_resolve_handler(real_class)

          if handler
            handler.call(HandlerApi.new(self), real_class, records)
          else
            bulk_insert(real_class, records)
          end
        end
      end

      def cache_or_resolve_handler(klass)
        @handlers_cache[klass] = resolve_handler(klass) unless @handlers_cache.key?(klass)

        @handlers_cache[klass]
      end

      # Look up a handler for `klass` by walking its ancestor chain. Session
      # -local handlers (Session#on) take precedence over any Duplicator-level
      # handler, even one registered closer in the ancestor chain: the two
      # passes below are deliberate, not a refactor opportunity.
      #: (Class) -> Proc?
      def resolve_handler(klass)
        # rubocop:disable Style/CombinableLoops
        klass.ancestors.each do |ancestor|
          return @user_handlers[ancestor] if @user_handlers.key?(ancestor)
        end
        klass.ancestors.each do |ancestor|
          return @handlers[ancestor] if @handlers.key?(ancestor)
        end
        # rubocop:enable Style/CombinableLoops
        nil
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
            new_values = fetch_new_id(reflection.klass, old_id: old_values)
            fk.zip(new_values).each { |c, v| attrs[c] = v }
          end
        else
          old_value = old_record[fk]
          attrs[fk] = old_value.nil? ? nil : fetch_new_id(reflection.klass, old_id: old_value)
        end
      end

      # Primary key columns whose values are filled in by the database (e.g. a
      # bigserial `id`). These must be stripped from the attributes before
      # calling insert_all! so the DB can assign fresh values. Composite pk
      # columns without a default_function (e.g. tenant_id) are kept.
      #: (Class) -> Array[String]
      def auto_generated_pk_columns(klass)
        Array.wrap(klass.primary_key).select do |key|
          column = klass.column_for_attribute(key)
          column.default_function.present?
        end
      end
    end
  end
end
