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
      def mark_skip(...)
        @session.mark_skip(...)
      end

      #: (*Class) -> void
      def mark_skip_class(...)
        @session.mark_skip_class(...)
      end

      #: (Class, old_id: untyped, new_id: untyped) -> void
      def store_new_id(...)
        @session.store_new_id(...)
      end

      #: (Class, old_id: untyped) -> untyped
      def fetch_new_id(...)
        @session.fetch_new_id(...)
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
