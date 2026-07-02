# frozen_string_literal: true

require_relative "lib/active_record/duplicator/version"

Gem::Specification.new do |spec|
  spec.name = "activerecord-duplicator"
  spec.version = ActiveRecord::Duplicator::VERSION
  spec.authors = ["alpaca-tc"]
  spec.email = ["alpaca-tc@alpaca.tc"]

  spec.summary = "Duplicate ActiveRecord records together with their associations, backed by bulk inserts."
  spec.description = <<~DESC
    activerecord-duplicator copies an ActiveRecord record and its associated rows
    (has_many, has_one, belongs_to, has_many :through) in one call. It rewires
    foreign keys through an internal id map, bypasses callbacks by using
    insert_all!, and lets you plug in per-model handlers for records that need
    custom logic. Composite primary keys (Rails 7.1+) are supported.
  DESC
  spec.homepage = "https://github.com/alpaca-tc/activerecord-duplicator"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[
                        bin/ Gemfile Gemfile.lock .gitignore .rspec spec/ .github/
                        .rubocop.yml compose.yml Appraisals Rakefile gemfiles/
                      ])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Rails 7.1 reached EOL on 2025-10-01; only supported minor versions
  # (7.2 / 8.0 / 8.1) are allowed as of this release.
  spec.add_dependency "activerecord", ">= 7.2"
  spec.add_dependency "pg", ">= 1.5"
end
