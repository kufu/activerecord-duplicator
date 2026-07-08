# frozen_string_literal: true

module ActiveRecordDuplicatorSpecSupport
  # Predicates for gating adapter-specific specs. Exposed as RSpec example
  # metadata so specs can say `context "...", :postgresql_only do ... end`
  # or filter with `it "...", if: postgresql? do ... end`.
  module Adapters
    module_function

    def adapter_name
      ActiveRecord::Base.connection.adapter_name
    end

    def postgresql?
      adapter_name.match?(/postgres/i)
    end

    def sqlite?
      adapter_name.match?(/sqlite/i)
    end
  end
end

RSpec.configure do |config|
  config.include(ActiveRecordDuplicatorSpecSupport::Adapters)
  config.extend(ActiveRecordDuplicatorSpecSupport::Adapters)

  # Skip specs tagged as PostgreSQL-only when running against another adapter
  # (e.g. composite primary keys with `bigserial`, which SQLite cannot
  # auto-increment on a non-solitary primary key column).
  config.filter_run_excluding(postgresql_only: true) unless ActiveRecordDuplicatorSpecSupport::Adapters.postgresql?
end
