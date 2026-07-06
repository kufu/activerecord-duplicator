# frozen_string_literal: true

require_relative "lib/active_record/duplicator/version"

Gem::Specification.new do |spec|
  spec.name = "activerecord-duplicator"
  spec.version = ActiveRecord::Duplicator::VERSION
  spec.authors = ["SmartHR"]
  spec.email = ["oss@smarthr.co.jp"]

  spec.summary = "Duplicate ActiveRecord records together with their associations, backed by bulk inserts."
  spec.description = <<~DESC
    activerecord-duplicator copies an ActiveRecord record and its associated rows
    (has_many, has_one, belongs_to, has_many :through) in one call. It rewires
    foreign keys through an internal id map, bypasses callbacks by using
    insert_all!, and lets you plug in per-model handlers for records that need
    custom logic. Composite primary keys (Rails 7.1+) are supported.
  DESC
  spec.homepage = "https://github.com/kufu/activerecord-duplicator"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "sig/**/*", "CHANGELOG.md", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  # Rails 7.2 is excluded because in_batches(cursor:) is only available on
  # ActiveRecord >= 8.0; supporting 7.2 would force a runtime branch on
  # every bulk_insert call.
  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "pg", ">= 1.5"
end
