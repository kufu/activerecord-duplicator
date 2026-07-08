# frozen_string_literal: true

require "active_record"
require "active_record/duplicator"

# Pick the adapter under test. `ARCONN` (e.g. `ARCONN=sqlite3 bundle exec rspec`)
# switches every spec to run against a different adapter without touching any
# per-spec configuration; the default keeps the PostgreSQL instance started by
# compose.yml so the local developer workflow is unchanged.
ARCONN = ENV.fetch("ARCONN", "postgresql")

case ARCONN
when "postgresql", "pg", "postgres"
  ActiveRecord::Base.establish_connection(
    ENV.fetch("DATABASE_URL", "postgres://postgres:password@localhost:55432/activerecord_duplicator_test"),
  )
when "sqlite3"
  # A single shared :memory: database is used for the whole run. `pool: 1`
  # keeps every ActiveRecord::Base.connection call on the same underlying
  # sqlite3 handle so `ATTACH DATABASE ':memory:' AS ...` (used by
  # IsolatedSchema) remains visible across specs.
  ActiveRecord::Base.establish_connection(
    adapter: "sqlite3",
    database: ":memory:",
    pool: 1,
  )
else
  raise "unknown ARCONN=#{ARCONN.inspect}; expected 'postgresql' or 'sqlite3'"
end

# Load shared spec helpers.
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
