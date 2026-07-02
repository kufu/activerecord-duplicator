# frozen_string_literal: true

require "active_record"
require "activerecord/duplicator"

# compose.yml で起動する PostgreSQL に接続する
# CI などで別の接続先を使いたい場合は DATABASE_URL 環境変数で上書きする
ActiveRecord::Base.establish_connection(
  ENV.fetch("DATABASE_URL", "postgres://postgres:password@localhost:15432/activerecord_duplicator_test"),
)

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
