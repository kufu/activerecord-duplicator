# frozen_string_literal: true

require "active_record"

require_relative "duplicator/version"
require_relative "duplicator/association_traversal"

module ActiveRecord
  module Duplicator
    class Error < StandardError; end
  end
end
