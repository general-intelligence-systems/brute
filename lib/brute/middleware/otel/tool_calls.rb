# frozen_string_literal: true

module Brute
  module Middleware
    module OTel
      # Records tool calls the LLM requested as span events.
      #
      # Runs POST-call: after the LLM responds, inspects ctx.functions
      # for any tool calls the model wants to make, and adds a span event
      # for each one with the tool name, call ID, and arguments.
      #
      class ToolCalls < Base
        def call(env)
          response = @app.call(env)

          span = env[:span]
          if span
            functions = env[:context].functions
            if functions && !functions.empty?
              span.set_attribute("brute.tool_calls.count", functions.size)

              functions.each do |fn|
                attrs = {
                  "tool.name" => fn.name.to_s,
                  "tool.id" => fn.id.to_s,
                }
                args = fn.arguments
                attrs["tool.arguments"] = args.to_json if args
                span.add_event("tool_call", attributes: attrs)
              end
            end
          end

          response
        end
      end
    end
  end
end
