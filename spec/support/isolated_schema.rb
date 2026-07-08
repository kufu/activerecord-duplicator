# frozen_string_literal: true

module ActiveRecordDuplicatorSpecSupport
  # Provides an `isolated_schema` DSL for RSpec describe/context blocks.
  #
  # Usage:
  #   isolated_schema "duplicator_spec" do |schema|
  #     schema.create_table :owners do |t|
  #       t.string :name
  #     end
  #   end
  #
  # In the spec bodies, refer to tables with the flattened name
  # `duplicator_spec_owners` (schema name + `_` + table name). The prefix is
  # applied automatically by the Builder so tables never collide across spec
  # groups, and every table is dropped in the `after(:all)` hook so no state
  # leaks out of the group.
  #
  # A flat naming scheme (rather than a real PostgreSQL SCHEMA or a SQLite
  # ATTACH DATABASE) is used because AR's SQLite adapter cannot introspect
  # columns of an attached-database table (the PRAGMA it emits is not
  # schema-qualified). Keeping one scheme across adapters means the specs stay
  # adapter-agnostic.
  #
  # ActiveRecord::Schema.define is deliberately avoided: it would create
  # ar_internal_metadata and schema_migrations as a side effect. We call
  # connection.create_table directly to keep the default namespace untouched.
  module IsolatedSchema
    def isolated_schema(schema_name, &block)
      before(:all) do
        conn = ActiveRecord::Base.connection
        builder = Builder.new(conn, schema_name)
        block&.call(builder)
        @__isolated_schema_created_tables = builder.created_tables
      end

      after(:all) do
        conn = ActiveRecord::Base.connection
        # Drop in reverse creation order so tables referenced by later ones
        # (e.g. via a foreign key) are dropped after their dependents.
        Array(@__isolated_schema_created_tables).reverse_each do |table|
          conn.drop_table(table, if_exists: true)
        end
      end
    end

    class Builder
      attr_reader :created_tables

      def initialize(connection, schema_name)
        @connection = connection
        @schema_name = schema_name
        @created_tables = []
      end

      # Forwards to ActiveRecord::ConnectionAdapters::SchemaStatements#create_table
      # with the table name automatically prefixed by the isolated schema so
      # spec groups never collide.
      def create_table(table_name, **, &)
        prefixed = "#{@schema_name}_#{table_name}"
        # DROP any leftover from a previous crashed run so create_table does
        # not fail on the "table already exists" branch.
        @connection.drop_table(prefixed, if_exists: true)
        @connection.create_table(prefixed, **, &)
        @created_tables << prefixed
      end
    end
  end
end

RSpec.configure do |config|
  config.extend(ActiveRecordDuplicatorSpecSupport::IsolatedSchema)
end
