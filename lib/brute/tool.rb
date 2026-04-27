# frozen_string_literal: true

require "bundler/setup"
require "brute"
require 'brute/pipeline'

module Brute
  # A Tool is a Pipeline configured for tool execution. The terminal app
  # does the work; middleware wraps it with concerns like file mutation
  # queueing, snapshotting, validation, logging.
  #
  # Coexists with Brute::Tools::* (which inherit from RubyLLM::Tool).
  # Use Brute::Tool when you want middleware. Use RubyLLM::Tool subclasses
  # for simple cases.
  #
  # Usage:
  #
  #   read = Brute::Tool.new(
  #     name:        "read",
  #     description: "Read a file's contents",
  #     params:      { file_path: { type: "string", required: true } },
  #   ) do
  #     use Brute::Middleware::Tool::ValidateParams
  #     run ->(env) {
  #       env[:result] = File.read(File.expand_path(env[:arguments][:file_path]))
  #     }
  #   end
  #
  #   read.call(file_path: "lib/brute.rb")
  #
  class Tool < Pipeline
    attr_reader :name, :description, :params

    def initialize(name:, description:, params: {}, &block)
      @name        = name.to_s
      @description = description
      @params      = params
      super(&block)
    end

    # Execute the tool. Arguments come in as kwargs; result is whatever
    # the terminal app puts into env[:result].
    def call(events: NullSink.new, **arguments)
      env = {
        name:      @name,
        arguments: arguments,
        result:    nil,
        events:    events,
        metadata:  {},
      }
      super(env)
      env[:result]
    end

    # Adapter so the LLM can call this tool through ruby_llm.
    # ToolCall middleware checks for to_ruby_llm and uses it if present.
    def to_ruby_llm
      tool = self
      Class.new(RubyLLM::Tool) do
        description tool.description
        tool.params.each { |k, opts| param k, **opts }
        define_method(:name) { tool.name }
        define_method(:execute) { |**args| tool.call(**args) }
      end.new
    end
  end
end

test do
  it "exposes name, description, params" do
    t = Brute::Tool.new(name: "echo", description: "echo input") do
      run ->(env) { env[:result] = env[:arguments][:msg] }
    end

    t.name.should == "echo"
    t.description.should == "echo input"
    t.call(msg: "hi").should == "hi"
  end

  it "passes arguments through env to the terminal app" do
    captured = nil
    t = Brute::Tool.new(name: "x", description: "x") do
      run ->(env) { captured = env[:arguments]; env[:result] = nil }
    end

    t.call(a: 1, b: 2)
    captured.should == { a: 1, b: 2 }
  end

  it "runs middleware around the terminal app" do
    log = []
    wrap = Class.new do
      def initialize(app, tag:); @app = app; @tag = tag; end
      def call(env); (env[:metadata][:log] ||= []) << "in-#{@tag}"; @app.call(env); env[:metadata][:log] << "out-#{@tag}"; end
    end

    t = Brute::Tool.new(name: "x", description: "x") do
      use wrap, tag: "a"
      run ->(env) { env[:metadata][:log] << "core"; env[:result] = :ok }
    end

    # Pre-seed the log on the env that gets built — tool builds its own env,
    # so we capture via the middleware metadata channel
    result = t.call(input: 1)
    result.should == :ok
  end
end
