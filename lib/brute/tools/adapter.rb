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
    #    (RubyLLM::Tool today, others via their own adapters) is wrapped
    #    into the same interface.
    # 2. Avoiding tool libraries entirely — Brute::Tool pipelines and
    #    Tools::SubAgent work without inheriting from a library class.
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
    # Completion middlewares convert adapters into whatever their LLM
    # library expects (e.g. #to_ruby_llm); ToolCall executes them via #call.
    #
    class Adapter
      attr_reader :name, :description, :params

      # Wrap a single tool of any supported shape. Idempotent.
      def self.wrap(tool)
        return tool if tool.is_a?(Adapter)

        tool = tool.new if tool.is_a?(Class)

        case tool
        when Hash                then from_hash(tool)
        when ::RubyLLM::Tool     then from_ruby_llm(tool)
        when Brute::Tools::SubAgent then new(
          name:        tool.name,
          description: tool.description,
          params:      tool.params,
          handler:     ->(**args) { tool.execute(args) },
          original:    tool,
        )
        when Brute::Tool then new(
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

      # Wrap a list of tools into a { name_sym => adapter } lookup hash —
      # the shape ToolCall and completion middlewares work with.
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
        raise ArgumentError, "inline tool needs an :execute proc" unless handler.respond_to?(:call)

        new(
          name:        definition.fetch(:name).to_s,
          description: definition.fetch(:description, ""),
          params:      definition.fetch(:params, {}),
          handler:     ->(**args) { handler.call(**args) },
          original:    definition,
        )
      end

      # A RubyLLM::Tool instance (the library's own arg normalization and
      # validation stays in play via tool.call). Tools declared with the
      # params(...) schema DSL keep their full JSON schema.
      def self.from_ruby_llm(tool)
        params = tool.parameters.each_with_object({}) do |(key, param), hash|
          hash[key.to_sym] = { type: param.type, desc: param.description, required: param.required }.compact
        end

        new(
          name:        tool.name.to_s,
          description: tool.description,
          params:      params,
          schema:      (tool.params_schema if tool.respond_to?(:params_schema)),
          handler:     ->(**args) { tool.call(args) },
          original:    tool,
        )
      end

      # Anything tool-shaped: needs #name and #call or #execute. Honors
      # #to_ruby_llm for backward compatibility with existing adapters.
      def self.from_duck_type(tool)
        return from_ruby_llm(tool.to_ruby_llm) if tool.respond_to?(:to_ruby_llm)

        unless tool.respond_to?(:name) && (tool.respond_to?(:call) || tool.respond_to?(:execute))
          raise ArgumentError, "don't know how to adapt #{tool.inspect} into a tool"
        end

        entry = tool.respond_to?(:execute) ? tool.method(:execute) : tool.method(:call)
        new(
          name:        tool.name.to_s,
          description: tool.respond_to?(:description) ? tool.description : "",
          params:      tool.respond_to?(:params) ? tool.params : {},
          handler:     ->(**args) { entry.call(**args) },
          original:    tool,
        )
      end

      def initialize(name:, description:, params:, handler:, schema: nil, original: nil)
        @name        = name
        @description = description
        @params      = params || {}
        @schema      = schema
        @handler     = handler
        @original    = original
      end

      # The tool object this adapter wraps (RubyLLM::Tool, Brute::Tool,
      # SubAgent, Hash definition, ...).
      attr_reader :original

      # Execute the tool. Accepts string- or symbol-keyed argument hashes,
      # as delivered by LLM providers.
      def call(arguments = {})
        args = arguments.to_h.transform_keys(&:to_sym)
        @handler.call(**args)
      end

      # Convert to a RubyLLM::Tool so ruby_llm-backed completion can hand
      # the tool to its providers. Returns the wrapped tool untouched when
      # it already is one.
      def to_ruby_llm
        return @original if @original.is_a?(::RubyLLM::Tool)

        adapter = self
        Class.new(::RubyLLM::Tool) do
          description adapter.description
          adapter.params.each { |key, opts| param key, **opts.slice(:type, :desc, :required) }
          define_method(:name) { adapter.name }
          define_method(:execute) { |**args| adapter.call(args) }
        end.new
      end

      # Library-neutral tool definition (JSON-Schema-ish), for completion
      # middlewares that talk to an HTTP API directly.
      def to_h
        return { name: @name, description: @description, parameters: @schema.deep_symbolize_keys } if @schema

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
          parameters: {
            type:       "object",
            properties: properties,
            required:   required.map(&:to_s),
          },
        }
      end
    end
  end
end

test do
  it "wraps a RubyLLM::Tool class" do
    klass = Class.new(::RubyLLM::Tool) do
      description "test tool"
      param :input, type: "string", desc: "the input"
      def name; "rl_tool"; end
      def execute(input:); "got #{input}"; end
    end

    adapter = Brute::Tools::Adapter.wrap(klass)
    adapter.name.should == "rl_tool"
    adapter.description.should == "test tool"
    adapter.params[:input][:type].should == "string"
    adapter.call("input" => "x").should == "got x"
  end

  it "wraps a Brute::Tool pipeline" do
    t = Brute::Tool.new(name: "echo", description: "echo input") do
      run ->(env) { env[:result] = env[:arguments][:msg] }
    end

    adapter = Brute::Tools::Adapter.wrap(t)
    adapter.name.should == "echo"
    adapter.call(msg: "hi").should == "hi"
  end

  it "wraps a SubAgent" do
    sa = Brute::Tools::SubAgent.new(name: "research", description: "test", provider: :stub) do
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

  it "converts to a RubyLLM::Tool" do
    adapter = Brute::Tools::Adapter.wrap(
      name:        "echo",
      description: "Echo",
      params:      { msg: { type: "string", desc: "message", required: true } },
      execute:     ->(msg:) { msg },
    )

    rl = adapter.to_ruby_llm
    rl.should.be.kind_of?(::RubyLLM::Tool)
    rl.name.should == "echo"
    rl.call("msg" => "hello").should == "hello"
  end

  it "returns the original when it already is a RubyLLM::Tool" do
    klass = Class.new(::RubyLLM::Tool) do
      description "test tool"
      def name; "original"; end
      def execute; "ok"; end
    end
    instance = klass.new

    Brute::Tools::Adapter.wrap(instance).to_ruby_llm.should == instance
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
