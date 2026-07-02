# frozen_string_literal: true

module ActiveRecord
  module Duplicator
    # Reusable configuration for record duplication.
    #
    # A Config holds per-model handler registrations; it does not hold any
    # per-run state (the id map lives on Session). Freeze after registering
    # handlers to enforce immutability across many duplication runs.
    #
    # Example:
    #   duplicator = ActiveRecord::Duplicator.new
    #   duplicator.on(Attachment) { |api, klass, records| ... }
    #   duplicator.freeze
    #
    #   new_root = duplicator.duplicate(old_root, associations: [...]) do |session|
    #     session.mark_skip(tenant)
    #   end
    class Config
      # @rbs @handlers: Hash[Class, Proc]

      #: () -> void
      def initialize
        @handlers = {}
      end

      # Register a custom handler for the given model class. See
      # HandlerApi for the API the block receives.
      #
      # Raises DuplicateHandlerError when the same class is registered twice.
      #: (Class) { (HandlerApi, Class, untyped) -> void } -> void
      def on(klass, &block)
        raise DuplicateHandlerError, "handler for #{klass} is already registered" if @handlers.key?(klass)

        @handlers[klass] = block
      end

      # Prevent further registrations. Also freezes the internal handler map so
      # accidental mutation later fails loudly.
      #: () -> self
      def freeze
        @handlers.freeze
        super
      end

      # Run one duplication. A fresh Session (with a fresh record id map) is
      # created for every invocation, so state does not leak between runs.
      #
      # If a block is given it is called with the new Session before duplication
      # starts, letting the caller mark_skip or store_new_id for records that
      # were duplicated elsewhere.
      #: (ActiveRecord::Base, ?associations: untyped) ?{ (Session) -> void } -> ActiveRecord::Base
      def duplicate(root_record, associations: [], &block)
        session = Session.new(handlers: @handlers)
        block&.call(session)
        session.__send__(:perform, root_record, associations: associations)
      end
    end
  end
end
