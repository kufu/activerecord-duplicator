# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in activerecord-duplicator.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "rubocop", ">= 1.21"

gem "rbs-inline", ">= 0.14"

gem "appraisal", ">= 2.5"

# Database adapters used by the spec suite. The gem itself does not depend
# on either; applications choose. We install both so `ARCONN=postgresql`
# (default) and `ARCONN=sqlite3` can both be exercised without changing the
# Gemfile.
gem "pg", ">= 1.5"
gem "sqlite3", ">= 2.0"
