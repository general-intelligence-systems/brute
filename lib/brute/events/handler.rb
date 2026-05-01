# frozen_string_literal: true

require 'bundler/setup'
require 'brute'

module Brute
  # @namespace
  module Events
    # Stackable event handler base class. Subclasses override the
    # append method, do their thing, then call super (or don't, to
    # swallow the event).
    class Handler
      def initialize(inner)
        @inner = inner
      end

      # Default: pass through. Subclasses override this method, do their
      # thing, then call super (or don't, to swallow the event).
      def <<(event)
        tap do
          @inner << event if @inner
        end
      end
    end
  end
end

test do
  # not implemented
end
