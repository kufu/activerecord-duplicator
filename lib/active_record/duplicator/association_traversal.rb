# frozen_string_literal: true

module ActiveRecord
  module Duplicator
    # Breadth-first traversal of associations declared with preload-style syntax.
    # Yields ActiveRecord::Relation objects in the order they would be needed to
    # duplicate records level by level.
    #
    # @example
    #   traversal = ActiveRecord::Duplicator::AssociationTraversal.new(
    #     owner,
    #     [items: :taggings],
    #   )
    #   traversal.each do |relation|
    #     # 1st: Relation of items belonging to owner
    #     # 2nd: Relation of taggings belonging to those items
    #   end
    class AssociationTraversal
      include Enumerable

      # @param record [ActiveRecord::Base, Array<ActiveRecord::Base>] root record(s) to traverse from
      # @param associations [Array, Hash, Symbol, String] preload-style association specification
      def initialize(record, associations)
        @record = record
        @associations = associations
      end

      def each(&block)
        Array.wrap(@associations).flat_map do |association|
          traverse(@record.class, association, Array.wrap(@record), &block)
        end
      end

      private

      def traverse(klass, association, records, &block)
        case association
        when Hash
          traverse_hash(klass, association, records, &block)
        when Symbol, String
          traverse_leaf(klass, association, records, &block)
        else
          raise ArgumentError, "#{association.inspect} is not a valid association form"
        end
      end

      def traverse_leaf(klass, association, records, &block)
        reflection = find_reflection(klass, association)
        yield_relation(reflection, records, &block)
      end

      def traverse_hash(klass, association, records, &block)
        association.flat_map do |parent, children|
          reflection = find_reflection(klass, parent)

          yield_relation(reflection, records) do |relation|
            block&.call(relation)

            Array.wrap(children).flat_map do |child|
              traverse(relation.klass, child, relation, &block)
            end
          end
        end
      end

      def yield_relation(reflection, records)
        relation = build_relation(reflection.klass, reflection, records)
        yield relation if block_given?
      end

      # Resolves the intermediate through_reflection first, then replaces it with the
      # source_reflection. For has_many/has_one it looks up children by matching the
      # parent's primary key against the child's foreign key. For belongs_to it looks
      # up the parent by matching the child's foreign key against the parent's primary key.
      def build_relation(klass, reflection, records)
        if reflection.through_reflection?
          records = build_relation(reflection.through_reflection.klass, reflection.through_reflection, records)
          reflection = reflection.source_reflection
        end

        if reflection.collection? || reflection.has_one?
          primary_ids = collect_ids(records, reflection.active_record_primary_key)
          klass.where(reflection.foreign_key => primary_ids)
        elsif reflection.belongs_to?
          primary_ids = collect_ids(records, reflection.foreign_key)
          klass.where(reflection.active_record_primary_key => primary_ids)
        else
          raise NotImplementedError, "reflection kind #{reflection.class.name} is not supported"
        end
      end

      def find_reflection(klass, association)
        reflection = klass.reflect_on_association(association)
        raise ArgumentError, "#{klass.name} has no association #{association}" if reflection.nil?

        reflection
      end

      # Avoid instantiating ActiveRecord objects just to read an id:
      # use pluck for Relations and map for plain arrays.
      def collect_ids(records, column_name)
        if records.is_a?(ActiveRecord::Relation)
          records.pluck(column_name)
        else
          records.map { _1.public_send(column_name) }
        end
      end
    end
  end
end
