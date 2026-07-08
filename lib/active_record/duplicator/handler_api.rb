# frozen_string_literal: true

module ActiveRecord
  class Duplicator
    # The public API surface handed to blocks registered via Session#on.
    # Wraps the current Session and exposes only the subset of methods a
    # handler should call. Session-level methods such as on and duplicate are
    # intentionally not surfaced here.
    class HandlerApi
      # @rbs @session: Session

      #: (Session) -> void
      def initialize(session)
        @session = session
      end

      #: (*ActiveRecord::Base) -> void
      def no_duplicate(...)
        @session.no_duplicate(...)
      end

      #: (Class, *untyped) -> void
      def no_duplicate_id(...)
        @session.no_duplicate_id(...)
      end

      #: (*Class) -> void
      def no_duplicate_class(...)
        @session.no_duplicate_class(...)
      end

      #: (Class, old_id: untyped, new_id: untyped) -> void
      def store_duplicate_id(...)
        @session.store_duplicate_id(...)
      end

      #: (Class, old_id: untyped) -> untyped
      def fetch_duplicate_id(...)
        @session.fetch_duplicate_id(...)
      end

      #: (Class, untyped, ?batch_size: Integer, ?cursor: untyped) -> void
      def bulk_insert(...)
        @session.bulk_insert(...)
      end

      #: (Class, ActiveRecord::Base) -> Hash[String, untyped]
      def attributes_for(...)
        @session.attributes_for(...)
      end
    end
  end
end
