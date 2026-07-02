# frozen_string_literal: true

module ActiveRecord
  module Duplicator
    # Breadth-first traversal of associations declared with preload-style syntax.
    # Yields ActiveRecord::Relation objects in the order they would be needed to
    # duplicate records level by level.
    #
    # Example:
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

      # @rbs @record: untyped
      # @rbs @associations: untyped

      #: (untyped record, untyped associations) -> void
      def initialize(record, associations)
        @record = record
        @associations = associations
      end

      #: () { (ActiveRecord::Relation) -> void } -> Array[untyped]
      def each(&block)
        Array.wrap(@associations).flat_map do |association|
          traverse(@record.class, association, Array.wrap(@record), &block)
        end
      end

      private

      #: (Class, untyped, untyped) { (ActiveRecord::Relation) -> void } -> Array[untyped]
      def traverse(klass, association, records, &)
        case association
        when Hash
          traverse_hash(klass, association, records, &)
        when Symbol, String
          traverse_leaf(klass, association, records, &)
        else
          raise ArgumentError, "#{association.inspect} is not a valid association form"
        end
      end

      #: (Class, Symbol | String, untyped) { (ActiveRecord::Relation) -> void } -> untyped
      def traverse_leaf(klass, association, records, &)
        reflection = find_reflection(klass, association)
        yield_relation(reflection, records, &)
      end

      #: (Class, Hash[Symbol | String, untyped], untyped) { (ActiveRecord::Relation) -> void } -> Array[untyped]
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

      #: (untyped reflection, untyped records) { (ActiveRecord::Relation) -> void } -> untyped
      def yield_relation(reflection, records)
        relation = build_relation(reflection.klass, reflection, records)
        yield relation if block_given?
      end

      # Resolves the intermediate through_reflection first, then replaces it with the
      # source_reflection. For has_many/has_one it looks up children by matching the
      # parent's primary key against the child's foreign key. For belongs_to it looks
      # up the parent by matching the child's foreign key against the parent's primary key.
      #
      # For composite primary keys the foreign_key / active_record_primary_key of a
      # reflection is an Array of column names; the corresponding WHERE clause uses
      # tuple syntax like `where([:a, :b] => [[v1, v2], [v3, v4]])`.
      #: (Class, untyped, untyped) -> ActiveRecord::Relation
      def build_relation(klass, reflection, records)
        if reflection.through_reflection?
          records = build_relation(reflection.through_reflection.klass, reflection.through_reflection, records)
          reflection = reflection.source_reflection
        end

        if reflection.collection? || reflection.has_one?
          lookup_columns = Array.wrap(reflection.active_record_primary_key)
          filter_columns = Array.wrap(reflection.foreign_key)
        elsif reflection.belongs_to?
          lookup_columns = Array.wrap(reflection.foreign_key)
          filter_columns = Array.wrap(reflection.active_record_primary_key)
        else
          raise NotImplementedError, "reflection kind #{reflection.class.name} is not supported"
        end

        ids = collect_ids(records, lookup_columns)
        klass.where(where_key(filter_columns) => ids)
      end

      #: (Class, Symbol | String) -> untyped
      def find_reflection(klass, association)
        reflection = klass.reflect_on_association(association)
        raise ArgumentError, "#{klass.name} has no association #{association}" if reflection.nil?

        reflection
      end

      # Rails accepts either a scalar column name or an Array of column names
      # as the LHS of a WHERE clause. For single-column pk we hand it a scalar
      # so the generated SQL stays as `WHERE col IN (...)`.
      #: (Array[Symbol | String]) -> (Symbol | String | Array[Symbol | String])
      def where_key(columns)
        columns.length == 1 ? columns.first : columns
      end

      # Avoid instantiating ActiveRecord objects just to read ids:
      # use pluck for Relations and map for plain arrays. For composite pk
      # returns an Array of Arrays (`[[v1, v2], ...]`); for single-column pk
      # returns a flat Array (`[v1, v2, ...]`).
      #: (untyped, Array[Symbol | String]) -> Array[untyped]
      def collect_ids(records, columns)
        if records.is_a?(ActiveRecord::Relation)
          if columns.length == 1
            records.pluck(columns.first)
          else
            records.pluck(*columns)
          end
        else
          records.map do |r|
            if columns.length == 1
              r.public_send(columns.first)
            else
              columns.map { |c| r.public_send(c) }
            end
          end
        end
      end
    end
  end
end
