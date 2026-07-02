# frozen_string_literal: true

require "active_record"
require "active_record/duplicator"

# Connect to the PostgreSQL instance started by compose.yml.
# Override with DATABASE_URL when running against a different database (e.g. in CI).
ActiveRecord::Base.establish_connection(
  ENV.fetch("DATABASE_URL", "postgres://postgres:password@localhost:15432/activerecord_duplicator_test"),
)

# Load shared spec helpers.
Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
