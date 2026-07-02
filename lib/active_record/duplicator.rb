# frozen_string_literal: true

require "active_record"

require_relative "duplicator/version"
require_relative "duplicator/errors"
require_relative "duplicator/association_traversal"
require_relative "duplicator/handler_api"
require_relative "duplicator/session"

module ActiveRecord
  module Duplicator
    # Create a new duplication session. Returns an
    # ActiveRecord::Duplicator::Session instance, but users normally do not
    # need to name that class explicitly.
    #: () -> Session
    def self.new
      Session.new
    end
  end
end
