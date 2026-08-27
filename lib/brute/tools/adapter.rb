# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Tools
    # Normalizes any tool shape into one neutral interface so the rest of
    # Brute never has to care which tools library (if any) a tool was
    # written with.
    #
    # This solves three problems:
    #
    # 1. Using any tools library — anything that quacks like a tool
    #    (#name plus #call or #execute) is wrapped into the same interface.
    # 2. Avoiding tool libraries entirely — Brute::Tool, Brute::Turn::ToolPipeline
    #    and Tools::SubAgent work without inheriting from a library class.
    # 3. Quickly adding tools — a plain Hash with a proc is enough:
    #
    #      Brute::Tools::Adapter.wrap(
    #        name:        "echo",
    #        description: "Echo the input back",
    #        params:      { msg: { type: "string", required: true } },
    #        execute:     ->(msg:) { msg },
    #      )
    #
    # The neutral interface:
    #
    #   adapter.name        # String
    #   adapter.description # String
    #   adapter.params      # { key => { type:, desc:, required: } }
    #   adapter.call(args)  # execute with a (string- or symbol-keyed) Hash
    #
    # The inline `run` proc converts adapters (via #to_h) into whatever its
    # LLM library expects; ToolPipeline executes them via #call.
    #
    class Adapter
      attr_reader :name, :description, :params

      # Wrap a single tool of any supported shape. Idempotent.
      def self.wrap(tool)
        if tool.is_a?(Adapter)
          tool
        else
          if tool.is_a?(Class)
            tool = tool.new
          end
          case tool
          when Hash                then from_hash(tool)
          when ::Brute::Tool       then from_brute_tool(tool)
          when Brute::Tools::SubAgent then new(
            name:        tool.name,
            description: tool.description,
            params:      tool.params,
            handler:     ->(**args) { tool.execute(args) },
            original:    tool,
          )
          when Brute::Turn::ToolPipeline then new(
            name:        tool.name,
            description: tool.description,
            params:      tool.params,
            handler:     ->(**args) { tool.call(**args) },
            original:    tool,
          )
          else
            from_duck_type(tool)
          end
        end
      end

      # Wrap a list of tools into a { name_sym => adapter } lookup hash —
      # the shape ToolPipeline works with.
      def self.wrap_all(tools)
        Array(tools).each_with_object({}) do |tool, hash|
          adapter = wrap(tool)
          hash[adapter.name.to_sym] = adapter
        end
      end

      # Quick inline tool: { name:, description:, params:, execute: }
      def self.from_hash(definition)
        definition = definition.transform_keys(&:to_sym)
        handler = definition.fetch(:execute) { definition[:handler] }
        unless handler.respond_to?(:call)
          raise ArgumentError, "inline tool needs an :execute proc"
        end

        new(
          name:        definition.fetch(:name).to_s,
          description: definition.fetch(:description, ""),
          params:      definition.fetch(:params, {}),
          handler:     ->(**args) { handler.call(**args) },
          original:    definition,
        )
      end

      # A Brute::Tool instance. Tools declared with the params({...}) schema
      # DSL keep their full JSON schema.
      def self.from_brute_tool(tool)
        new(
          name:        tool.name.to_s,
          description: tool.description,
          params:      tool.params,
          schema:      tool.params_schema,
          handler:     ->(**args) { tool.call(args) },
          original:    tool,
        )
      end

      # Anything tool-shaped: needs #name and #call or #execute.
      def self.from_duck_type(tool)
        unless tool.respond_to?(:name) && (tool.respond_to?(:call) || tool.respond_to?(:execute))
          raise ArgumentError, "don't know how to adapt #{tool.inspect} into a tool"
        end

        if tool.respond_to?(:execute)
          entry = tool.method(:execute)
        else
          entry = tool.method(:call)
        end
        new(
          name:        tool.name.to_s,
          description: tool.respond_to?(:description) ? tool.description : "",
          params:      tool.respond_to?(:params) ? tool.params : {},
          handler:     ->(**args) { entry.call(**args) },
          original:    tool,
        )
      end

      # The tool object this adapter wraps (Brute::Tool, Brute::Turn::ToolPipeline,
      # SubAgent, Hash definition, ...).
      attr_reader :original

      def initialize(name:, description:, params:, handler:, schema: nil, original: nil)
        @name        = name
        @description = description
        @params      = params || {}
        @schema      = schema
        @handler     = handler
        @original    = original
      end

      # Execute the tool. Accepts string- or symbol-keyed argument hashes,
      # as delivered by LLM providers.
      def call(arguments = {})
        args = arguments.to_h.transform_keys(&:to_sym)
        @handler.call(**args)
      end

      # Library-neutral tool definition (JSON-Schema-ish). The inline `run`
      # proc reshapes this into whatever its LLM library expects.
      def to_h
        if @schema
          { name: @name, description: @description, parameters: @schema.deep_symbolize_keys }
        else
          properties = @params.transform_values do |opts|
            {
              type:        opts[:type] || "string",
              description: opts[:desc] || opts[:description],
              items:       opts[:items],
              enum:        opts[:enum],
            }.compact
          end
          required = @params.select { |_k, opts| opts[:required] }.keys
          {
            name:        @name,
            description: @description,
            parameters:  {
              type:       "object",
              properties: properties,
              required:   required.map(&:to_s),
            },
          }
        end
      end
    end
  end
end

__END__

describe "brute/tools/adapter" do
  it "wraps a Brute::Tool class" do
    klass = Class.new(::Brute::Tool) do
      description "test tool"
      param :input, type: "string", desc: "the input"
      def name; "brute_tool"; end
      def execute(input:); "got #{input}"; end
    end

    adapter = Brute::Tools::Adapter.wrap(klass)
    adapter.name.should == "brute_tool"
    adapter.description.should == "test tool"
    adapter.params[:input][:type].should == "string"
    adapter.call("input" => "x").should == "got x"
  end

  it "wraps a Brute::Turn::ToolPipeline" do
    t = Brute::Turn::ToolPipeline.new(name: "echo", description: "echo input") do
      run ->(env) { env[:result] = env[:arguments][:msg] }
    end

    adapter = Brute::Tools::Adapter.wrap(t)
    adapter.name.should == "echo"
    adapter.call(msg: "hi").should == "hi"
  end

  it "wraps a SubAgent" do
    sa = Brute::Tools::SubAgent.new(name: "research", description: "test") do
      run ->(env) { env[:messages].assistant("result text") }
    end

    adapter = Brute::Tools::Adapter.wrap(sa)
    adapter.name.should == "research"
    adapter.call(task: "go").should == "result text"
  end

  it "wraps an inline hash definition" do
    adapter = Brute::Tools::Adapter.wrap(
      name:        "adder",
      description: "Add two numbers",
      params:      { a: { type: "number", required: true }, b: { type: "number", required: true } },
      execute:     ->(a:, b:) { a + b },
    )

    adapter.name.should == "adder"
    adapter.call(a: 1, b: 2).should == 3
  end

  it "is idempotent" do
    adapter = Brute::Tools::Adapter.wrap(name: "x", description: "", execute: -> {})
    Brute::Tools::Adapter.wrap(adapter).should == adapter
  end

  it "wrap_all keys adapters by name symbol" do
    tools = Brute::Tools::Adapter.wrap_all([
      { name: "a", description: "", execute: -> {} },
      { name: "b", description: "", execute: -> {} },
    ])
    tools.keys.should == [:a, :b]
    tools[:a].should.be.kind_of?(Brute::Tools::Adapter)
  end

  it "exposes the wrapped original" do
    klass = Class.new(::Brute::Tool) do
      description "test tool"
      def name; "original"; end
      def execute; "ok"; end
    end
    instance = klass.new

    Brute::Tools::Adapter.wrap(instance).original.should == instance
  end

  it "produces a neutral JSON-schema-ish definition" do
    adapter = Brute::Tools::Adapter.wrap(
      name:        "echo",
      description: "Echo",
      params:      { msg: { type: "string", desc: "message", required: true } },
      execute:     ->(msg:) { msg },
    )

    defn = adapter.to_h
    defn[:name].should == "echo"
    defn[:parameters][:properties][:msg][:type].should == "string"
    defn[:parameters][:required].should == ["msg"]
  end
end
