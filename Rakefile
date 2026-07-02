# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

namespace :rbs do
  desc "Regenerate sig/generated/ from rbs-inline annotations in lib/"
  task :inline do
    sh "bundle exec rbs-inline --opt-out --output lib"
  end
end

task default: %i[spec rubocop]
