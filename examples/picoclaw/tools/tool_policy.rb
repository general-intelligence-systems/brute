# frozen_string_literal: true

require_relative "tool_wrapper"

# ToolPolicy — the per-tool-call policy layer (picoclaw's pkg/tools/
# validate.go arg validation + registry.go:275-281 + the pipeline_execute.go
# sensitive-data filter + the ApproveTool seam). brute's per-call seam is a
# ToolWrapper around each tool (like WorkspaceGuard), so this lives in tools/,
# not middleware/.
#
#   1. validate arguments against the tool's declared JSON schema (before
#      execution; invalid → "invalid arguments for tool %q: ..." and the tool
#      never runs)
#   2. approval gate (approve proc; denies are fail-closed)
#   3. sensitive-data scrub of the result: every collected secret value is
#      replaced with [FILTERED] (tools.filter_sensitive_data, default true;
#      results shorter than filter_min_length — 8 — skip the scan)
#
# The allowlist half (AGENT.md frontmatter `tools:`) happens at registration
# in main.rb, like upstream's registry.SetAllowlist.
class ToolPolicy < ToolWrapper
  def initialize(tool, sensitive_values: [], filter_enabled: true, filter_min_length: 8, approve: nil)
    super(tool)
    @secrets = sensitive_values.map(&:to_s).reject { |v| v.length <= 3 } # upstream: len(v) > 3
    @filter_enabled = filter_enabled
    @filter_min_length = filter_min_length
    @approve = approve || ->(_name, _args) { true }
  end

  def call(arguments)
    args = arguments.to_h
    if (error = Validator.validate(schema, args))
      return %(invalid arguments for tool "#{name}": #{error})
    end

    unless @approve.call(name, args)
      return %(Tool call to "#{name}" was denied by the approval policy.)
    end

    result = @tool.call(args)
    scrub(result.to_s)
  end

  private

  # The Adapter doesn't forward params_schema — read it off the raw tool.
  def schema
    original = @tool.respond_to?(:original) ? @tool.original : @tool
    original.respond_to?(:params_schema) ? original.params_schema : nil
  end

  def scrub(content)
    return content unless @filter_enabled
    return content if content.length < @filter_min_length

    @secrets.each { |secret| content = content.gsub(secret, "[FILTERED]") }
    content
  end

  # validateToolArgs port (pkg/tools/validate.go): required + per-property
  # type checks; additionalProperties absent => extra keys rejected; object
  # properties recurse; array items recurse via the items schema.
  module Validator
    # Go %T names for JSON-arrival types.
    def self.go_type(value)
      case value
      when String then "string"
      when Integer, Float then "float64"
      when TrueClass, FalseClass then "bool"
      when Hash then "map[string]interface {}"
      when Array then "[]interface {}"
      when NilClass then "<nil>"
      else value.class.name
      end
    end

    def self.validate(schema, args)
      return nil if schema.nil? || schema.empty?

      schema = schema.transform_keys(&:to_sym)
      args = (args || {}).transform_keys(&:to_s)

      if (error = check_required(schema, args))
        return error
      end

      props = schema[:properties]
      return nil unless props.is_a?(Hash)

      additional = schema[:additionalProperties] == true
      args.each do |key, val|
        prop_schema = props[key.to_sym] || props[key]
        if prop_schema.nil?
          return %(unexpected property "#{key}") unless additional

          next
        end
        next unless prop_schema.is_a?(Hash)

        if (error = check_type(key, val, prop_schema.transform_keys(&:to_sym)))
          return error
        end
      end
      nil
    end

    def self.check_required(schema, args)
      Array(schema[:required]).each do |field|
        return %(missing required property "#{field}") unless args.key?(field.to_s)
      end
      nil
    end

    def self.check_type(key, val, prop_schema)
      case prop_schema[:type]
      when "string"
        %(property "#{key}": expected string, got #{go_type(val)}) unless val.is_a?(String)
      when "integer"
        if val.is_a?(Float) && val != val.truncate
          %(property "#{key}": expected integer, got float64 with fractional part)
        elsif !val.is_a?(Numeric) || val.is_a?(Complex)
          %(property "#{key}": expected integer, got #{go_type(val)})
        end
      when "number"
        %(property "#{key}": expected number, got #{go_type(val)}) unless val.is_a?(Numeric) && !val.is_a?(Complex)
      when "boolean"
        %(property "#{key}": expected boolean, got #{go_type(val)}) unless val.is_a?(TrueClass) || val.is_a?(FalseClass)
      when "array"
        if !val.is_a?(Array)
          %(property "#{key}": expected array, got #{go_type(val)})
        elsif (items = prop_schema[:items]).is_a?(Hash)
          val.each_with_index do |item, i|
            if (error = check_type("#{key}[#{i}]", item, items.transform_keys(&:to_sym)))
              return error
            end
          end
          nil
        end
      when "object"
        if !val.is_a?(Hash)
          %(property "#{key}": expected object, got #{go_type(val)})
        else
          validate(prop_schema, val)
        end
      end
    end
  end
end
