# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  # Base class for Brute's built-in tools — a tiny, framework-agnostic tool
  # DSL. It intentionally mirrors the common tool-library shape (description +
  # params) so tools read the same as they would in any LLM library, without
  # depending on one:
  #
  #   class Shell < Brute::Tool
  #     description "Execute a shell command"
  #     param :command, type: 'string', desc: "The command", required: true
  #
  #     def name; "shell"; end
  #
  #     def execute(command:)
  #       ...
  #     end
  #   end
  #
  # For tools whose arguments don't fit the flat param list, pass a raw JSON
  # schema instead:
  #
  #   params({ type: 'object', properties: { ... }, required: [...] })
  #
  # Instances expose the neutral interface Brute::Tools::Adapter understands:
  # #name, #description, #params, #params_schema, #call.
  class Tool
    class << self
      def description(text = nil)
        return @description unless text

        @description = text
      end

      # Declare one parameter: param :key, type:, desc:, required:
      def param(name, type: "string", desc: nil, required: true, **opts)
        param_definitions[name.to_sym] = { type: type, desc: desc, required: required, **opts }.compact
      end

      def param_definitions
        @param_definitions ||= {}
      end

      # Raw JSON-schema override for complex argument shapes.
      def params(schema = nil)
        return @params_schema unless schema

        @params_schema = schema.deep_symbolize_keys
      end
    end

    # Tool name; subclasses usually override with an explicit short name.
    def name
      self.class.name.demodulize.underscore
    end

    def description
      self.class.description.to_s
    end

    # { key => { type:, desc:, required: } }
    def params
      self.class.param_definitions
    end

    # The raw JSON schema, when declared via params({...}).
    def params_schema
      self.class.params
    end

    # Execute with a string- or symbol-keyed argument hash, as delivered
    # by LLM providers.
    def call(arguments = {})
      execute(**arguments.to_h.transform_keys(&:to_sym))
    end

    def execute(**)
      raise NotImplementedError, "#{self.class} must implement #execute"
    end
  end
end

__END__

describe "brute/tool" do
  it "exposes description and params from the DSL" do
    klass = Class.new(Brute::Tool) do
      description "test tool"
      param :input, type: "string", desc: "the input"
      def name; "t"; end
      def execute(input:); "got #{input}"; end
    end

    tool = klass.new
    tool.description.should == "test tool"
    tool.params[:input][:type].should == "string"
    tool.params[:input][:required].should.be.true
  end

  it "calls execute with symbolized keys" do
    klass = Class.new(Brute::Tool) do
      description "echo"
      param :msg, type: "string"
      def name; "echo"; end
      def execute(msg:); msg; end
    end

    klass.new.call("msg" => "hi").should == "hi"
  end

  it "accepts a raw JSON schema via params({...})" do
    klass = Class.new(Brute::Tool) do
      description "schema tool"
      params({ type: "object", properties: { a: { type: "string" } }, required: %w[a] })
      def name; "s"; end
      def execute(a:); a; end
    end

    klass.new.params_schema[:properties][:a][:type].should == "string"
  end
end
