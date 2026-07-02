# frozen_string_literal: true

module ActiveRecord
  module Duplicator
    # Coordinates one duplication session:
    #   * holds the record id map (old_id -> new_id, per class)
    #   * holds handler registrations for per-model custom logic
    #   * orchestrates duplicate() for a root record and its associations
    #
    # Users create a Session via ActiveRecord::Duplicator.new, which is a
    # factory that delegates here.
    class Session
      DEFAULT_BATCH_SIZE = 1000
      TIMESTAMP_COLUMNS = %w[created_at updated_at].freeze
      private_constant :DEFAULT_BATCH_SIZE, :TIMESTAMP_COLUMNS

      # @rbs @record_id_map: Hash[Class, Hash[untyped, untyped]]
      # @rbs @handlers: Hash[Class, Proc]
      #: () -> void
      def initialize
        @record_id_map = Hash.new { |hash, klass| hash[klass] = {} }
        @handlers = {}
      end

      # Declare that the given records must not be duplicated: their new_id
      # is set equal to their old_id, so any record duplicated later that
      # references them will keep pointing at the same rows.
      #: (*ActiveRecord::Base) -> void
      def mark_skip(*records)
        records.each do |record|
          store_new_id(record.class, old_id: record.id, new_id: record.id)
        end
      end

      # Record a mapping from an old_id to a new_id. Called automatically from
      # bulk_insert; called explicitly by user code (or a handler) when new
      # records are produced outside of the default duplication path.
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

      # Look up a new_id by (klass, old_id).
      #
      # Raises MissingNewIdError when no mapping exists for the given
      # (klass, old_id). This usually means a belongs_to parent has not
      # been duplicated yet; place it earlier in the associations tree
      # or register/skip it explicitly.
      #: (Class, old_id: untyped) -> untyped
      def fetch_new_id(klass, old_id:)
        @record_id_map[klass].fetch(old_id) do
          raise MissingNewIdError, "no new_id registered for #{klass}##{old_id}"
        end
      end

      # Register a custom handler for the given model class. The block is
      # invoked instead of the default bulk_insert whenever records of `klass`
      # need to be duplicated.
      #
      # The block receives (api, klass, records), where:
      #   * api is a HandlerApi facade over this Session
      #   * klass is the model class being duplicated
      #   * records is an ActiveRecord::Relation or Array of the records to copy
      #
      # The handler is responsible for producing new records and calling
      # api.store_new_id for each so the id map stays consistent.
      #
      # Raises DuplicateHandlerError when a handler is already registered for klass.
      #: (Class) { (HandlerApi, Class, untyped) -> void } -> void
      def on(klass, &block)
        if @handlers.key?(klass)
          raise DuplicateHandlerError, "handler for #{klass} is already registered"
        end

        @handlers[klass] = block
      end

      # Duplicate root_record together with the associations listed in
      # preload-style syntax. Returns the newly created root record, freshly
      # loaded from the database.
      #
      # The entire operation runs in a new, non-joinable transaction so that a
      # failure only rolls back the duplication and does not affect any outer
      # transaction the caller may have opened.
      #: (ActiveRecord::Base, ?associations: untyped) -> ActiveRecord::Base
      def duplicate(root_record, associations: [])
        root_record.transaction(requires_new: true, joinable: false) do
          duplicate_records(root_record.class, [root_record])

          AssociationTraversal.new(root_record, associations).each do |relation|
            duplicate_records(relation.klass, relation)
          end

          new_id = fetch_new_id(root_record.class, old_id: root_record.id)
          root_record.class.find(new_id)
        end
      end

      # Bulk-insert copies of the given records into klass, skipping any that
      # are already present in the id map. Handlers can reuse this via HandlerApi
      # to defer a subset of records to the default duplication path.
      #: (Class, untyped, ?batch_size: Integer, ?cursor: untyped) -> void
      def bulk_insert(klass, records, batch_size: DEFAULT_BATCH_SIZE, cursor: nil)
        batches = enumerate_batches(records, batch_size: batch_size, cursor: cursor)

        batches.each do |batch|
          old_records = batch.to_a
          old_records.reject! { |r| @record_id_map[klass].key?(r.id) }
          next if old_records.empty?

          rows = old_records.map { |r| attributes_for(klass, r) }
          new_ids = klass.insert_all!(rows)

          new_ids.to_a.pluck("id").each.with_index do |new_id, i|
            store_new_id(klass, old_id: old_records[i].id, new_id: new_id)
          end
        end
      end

      # Build the attribute Hash for a single record, ready to be handed to
      # insert_all!. The primary key, timestamps, and every belongs_to foreign
      # key are stripped; each belongs_to foreign key is then re-populated
      # from the id map so it points to the new parent.
      #: (Class, ActiveRecord::Base) -> Hash[String, untyped]
      def attributes_for(klass, old_record)
        belongs_to = klass.reflect_on_all_associations(:belongs_to)
        ignored = [klass.primary_key] + TIMESTAMP_COLUMNS + belongs_to.map(&:foreign_key)
        attrs = old_record.attributes.except(*ignored)

        belongs_to.each do |reflection|
          fk = reflection.foreign_key
          old_value = old_record[fk]
          attrs[fk] = old_value.nil? ? nil : fetch_new_id(reflection.klass, old_id: old_value)
        end

        attrs
      end

      private

      #: (Class, untyped) -> void
      def duplicate_records(klass, relation_or_records)
        handler = @handlers[klass]

        if handler
          handler.call(HandlerApi.new(self), klass, relation_or_records)
        else
          bulk_insert(klass, relation_or_records)
        end
      end

      #: (untyped, batch_size: Integer, cursor: untyped) -> untyped
      def enumerate_batches(records, batch_size:, cursor:)
        if records.respond_to?(:in_batches) && cursor
          records.in_batches(of: batch_size, cursor: cursor)
        elsif records.respond_to?(:find_in_batches)
          records.find_in_batches(batch_size: batch_size)
        else
          records.each_slice(batch_size)
        end
      end
    end
  end
end
