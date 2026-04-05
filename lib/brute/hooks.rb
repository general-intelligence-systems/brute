# frozen_string_literal: true

module Brute
  # Lifecycle hook system modeled after forgecode's Hook struct.
  #
  # Six lifecycle events fire during the orchestrator loop:
  #   :start           — conversation processing begins
  #   :end             — conversation processing ends
  #   :request         — before each LLM API call
  #   :response        — after each LLM response
  #   :toolcall_start  — before a tool executes
  #   :toolcall_end    — after a tool executes
  #
  # Hooks receive (event_name, context_hash) and can inspect or mutate
  # the orchestrator state via the context hash.
  module Hooks
    # Base class. Subclass and override #on_<event> methods.
    class Base
      def call(event, **data)
        method_name = :"on_#{event}"
        send(method_name, **data) if respond_to?(method_name, true)
      end

      private

      def on_start(**) = nil
      def on_end(**) = nil
      def on_request(**) = nil
      def on_response(**) = nil
      def on_toolcall_start(**) = nil
      def on_toolcall_end(**) = nil
    end

    # Composes multiple hooks into one, firing them in order.
    class Composite < Base
      def initialize(*hooks)
        @hooks = hooks
      end

      def call(event, **data)
        @hooks.each { |h| h.call(event, **data) }
      end

      def <<(hook)
        @hooks << hook
        self
      end
    end

    # Logs lifecycle events to a logger.
    class Logging < Base
      def initialize(logger)
        @logger = logger
      end

      private

      def on_start(**)
        @logger.info("[brute] Conversation started")
      end

      def on_end(**)
        @logger.info("[brute] Conversation ended")
      end

      def on_request(request_count: 0, **)
        @logger.debug("[brute] LLM request ##{request_count}")
      end

      def on_response(tokens: nil, **)
        @logger.debug("[brute] LLM response (tokens: #{tokens || "?"})")
      end

      def on_toolcall_start(tool_name: nil, **)
        @logger.info("[brute] Tool call: #{tool_name}")
      end

      def on_toolcall_end(tool_name: nil, error: false, **)
        status = error ? "FAILED" : "ok"
        @logger.info("[brute] Tool result: #{tool_name} [#{status}]")
      end
    end
  end
end
