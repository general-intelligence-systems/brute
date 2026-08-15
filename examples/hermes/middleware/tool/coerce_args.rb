# frozen_string_literal: true

require "json"

module Hermes
  module Middleware
    module Tool
      # CoerceArgs — schema-guided argument coercion (before).
      # Port of hermes-agent model_tools.py:777 coerce_tool_args:
      # models deliver strings; schemas want typed values.
      #   * "5" / "1.5"          → Integer/Float when the schema says number/integer
      #   * "true"/"false"       → true/false when it says boolean
      #   * '["a"]' / bare value → Array when it says array (JSON parse / wrap)
      #   * '{"k":1}'            → Hash when it says object
      #   * arg-name             → arg_name (sanitized-key unrename)
      class CoerceArgs
        def initialize(app, **_opts)
          @app = app
        end

        def call(env)
          env[:arguments] = coerce(env[:arguments] || {}, schema_for(env))
          @app.call(env)
        end

        private

        def schema_for(env)
          tool = env[:tool]
          return {} unless tool

          (tool.respond_to?(:params_schema) && tool.params_schema) || {}
        end

        def coerce(args, schema)
          props = schema[:properties] || schema["properties"] || {}
          args.each_with_object({}) do |(key, value), out|
            normalized = key.to_s.tr("-", "_").to_sym
            spec = props[normalized] || props[normalized.to_s] || {}
            out[normalized] = coerce_value(value, spec[:type] || spec["type"])
          end
        end

        def coerce_value(value, type)
          case type
          when "integer"
            value.is_a?(String) && value.strip =~ /\A-?\d+\z/ ? value.to_i : value
          when "number"
            value.is_a?(String) && value.strip =~ /\A-?\d+(\.\d+)?\z/ ? value.to_f : value
          when "boolean"
            case value
            when "true" then true
            when "false" then false
            else value
            end
          when "array"
            if value.is_a?(String)
              begin
                parsed = JSON.parse(value)
                parsed.is_a?(Array) ? parsed : [value]
              rescue JSON::ParserError
                [value]
              end
            else
              value.is_a?(Array) ? value : [value]
            end
          when "object"
            if value.is_a?(String)
              begin
                JSON.parse(value)
              rescue JSON::ParserError
                value
              end
            else
              value
            end
          else
            value
          end
        end
      end
    end
  end
end
