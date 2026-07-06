# frozen_string_literal: true

require "active_record"

module ActiveRecord
  # Reusable duplication configuration and entrypoint.
  #
  # A Duplicator holds only per-model handler registrations; it does not hold
  # any per-run state (the id map lives on Session). Freeze after registering
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
  class Duplicator
    # @rbs @handlers: Hash[Class, Proc]
    # @rbs @skipped_classes: Set[Class]

    #: () -> void
    def initialize
      @handlers = {}
      @skipped_classes = Set.new
    end

    # Register a custom handler for the given model class. See HandlerApi for
    # the API the block receives.
    #
    # Raises DuplicateHandlerError when the same class is registered twice.
    #: (Class) { (HandlerApi, Class, untyped) -> void } -> void
    def on(klass, &block)
      raise DuplicateHandlerError, "handler for #{klass} is already registered" if @handlers.key?(klass)

      @handlers[klass] = block
    end

    # Declare that every record of the given classes must not be duplicated in
    # any subsequent run. See Session#mark_skip_class for the semantics; the
    # Duplicator-level registration is applied to every fresh Session as its
    # baseline, and Session#mark_skip_class can extend it for a single run.
    # Repeated calls with the same class are idempotent.
    #: (*Class) -> void
    def mark_skip_class(*klasses)
      @skipped_classes.merge(klasses)
    end

    # Prevent further registrations. Also freezes the internal handler map so
    # accidental mutation later fails loudly.
    #: () -> self
    def freeze
      @handlers.freeze
      @skipped_classes.freeze
      super
    end

    # Run one duplication. A fresh Session (with a fresh record id map) is
    # created for every invocation, so state does not leak between runs.
    #
    # If a block is given it is called with the new Session before duplication
    # starts, letting the caller mark_skip or store_new_id for records that
    # were duplicated elsewhere.
    #
    # transaction_options is forwarded verbatim to Session#run, which forwards
    # it to `root_record.transaction`. Default is `{}` (plain
    # `transaction do ... end`).
    #: (ActiveRecord::Base, ?associations: untyped, ?transaction_options: Hash[Symbol, untyped]) ?{ (Session) -> void } -> ActiveRecord::Base
    def duplicate(root_record, associations: [], transaction_options: {}, &block)
      session = Session.new(handlers: @handlers, skipped_classes: @skipped_classes)
      block&.call(session)
      session.run(root_record, associations:, transaction_options:)
    end
  end
end

require_relative "duplicator/version"
require_relative "duplicator/errors"
require_relative "duplicator/association_traversal"
require_relative "duplicator/handler_api"
require_relative "duplicator/session"
