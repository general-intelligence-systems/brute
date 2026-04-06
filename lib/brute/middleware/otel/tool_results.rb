# frozen_string_literal: true

module Brute
  module Middleware
    module OTel
      # Records tool results being sent back to the LLM as span events.
      #
      # Runs PRE-call: when env[:tool_results] is present, the orchestrator
      # is sending tool execution results back to the LLM. Each result gets
      # a span event with the tool name and success/error status.
      #
      class ToolResults < Base
        def call(env)
          span = env[:span]

          if span && (results = env[:tool_results])
            span.set_attribute("brute.tool_results.count", results.size)

            results.each do |name, value|
              error = value.is_a?(Hash) && value[:error]
              attrs = { "tool.name" => name.to_s }
              if error
                attrs["tool.status"] = "error"
                attrs["tool.error"] = value[:error].to_s
              else
                attrs["tool.status"] = "ok"
              end
              span.add_event("tool_result", attributes: attrs)
            end
          end

          @app.call(env)
        end
      end
    end
  end
end
