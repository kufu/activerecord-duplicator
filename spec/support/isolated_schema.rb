# frozen_string_literal: true

module ActiveRecordDuplicatorSpecSupport
  # Provides an `isolated_schema` DSL for RSpec describe/context blocks.
  #
  # Usage:
  #   isolated_schema "name" do |schema|
  #     schema.create_table :owners do |t|
  #       t.string :name
  #     end
  #   end
  #
  # A dedicated PostgreSQL SCHEMA is created before the group runs and DROPped
  # (CASCADE) after it finishes, so no tables ever leak into the public schema.
  #
  # ActiveRecord::Schema.define is deliberately avoided: it would create
  # ar_internal_metadata and schema_migrations in the public schema as a side
  # effect. We call connection.create_table directly to keep the public schema
  # untouched.
  #
  # In the specs themselves, refer to tables with the schema-qualified name
  # ("name.owners"). Using search_path instead would be fragile because a
  # different connection from the pool might not see the setting.
  module IsolatedSchema
    def isolated_schema(schema_name, &block)
      before(:all) do
        conn = ActiveRecord::Base.connection
        quoted = conn.quote_table_name(schema_name)
        conn.execute("DROP SCHEMA IF EXISTS #{quoted} CASCADE")
        conn.execute("CREATE SCHEMA #{quoted}")

        block&.call(Builder.new(conn, schema_name))
      end

      after(:all) do
        conn = ActiveRecord::Base.connection
        conn.execute("DROP SCHEMA #{conn.quote_table_name(schema_name)} CASCADE")
      end
    end

    class Builder
      def initialize(connection, schema_name)
        @connection = connection
        @schema_name = schema_name
      end

      # Forwards to ActiveRecord::ConnectionAdapters::SchemaStatements#create_table
      # with the table name automatically qualified by the isolated schema.
      def create_table(table_name, **options, &block)
        @connection.create_table("#{@schema_name}.#{table_name}", **options, &block)
      end
    end
  end
end

RSpec.configure do |config|
  config.extend(ActiveRecordDuplicatorSpecSupport::IsolatedSchema)
end
