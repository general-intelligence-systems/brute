# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    module OTel
      # Records tool results as span events.
      #
      # Tool results are now appended directly to env[:messages] as :tool
      # role messages. This middleware can inspect the last messages to
      # record them as span events.
      #
      class ToolResults
        def initialize(app)
          @app = app
        end

        def call(env)
          #span = env[:span]

          #if span && (results = env[:tool_results])
          #  span.set_attribute("brute.tool_results.count", results.size)

          #  results.each do |name, value|
          #    error = value.is_a?(Hash) && value[:error]
          #    attrs = { "tool.name" => name.to_s }
          #    if error
          #      attrs["tool.status"] = "error"
          #      attrs["tool.error"] = value[:error].to_s
          #    else
          #      attrs["tool.status"] = "ok"
          #    end
          #    span.add_event("tool_result", attributes: attrs)
          #  end
          #end

          @app.call(env)
        end
      end
    end
  end
end

test do
  # not implemented
end
