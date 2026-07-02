# frozen_string_literal: true

require "active_record"

require_relative "duplicator/version"
require_relative "duplicator/errors"
require_relative "duplicator/association_traversal"
require_relative "duplicator/handler_api"
require_relative "duplicator/session"
require_relative "duplicator/config"

module ActiveRecord
  module Duplicator
    # Create a new duplication configuration. Register handlers on it with
    # #on and then run each duplication with #duplicate; a fresh Session
    # (with its own id map) is created per run.
    #: () -> Config
    def self.new
      Config.new
    end
  end
end
