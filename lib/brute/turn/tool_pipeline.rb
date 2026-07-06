# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/turn/pipeline"

module Brute
  module Turn
    # A ToolPipeline runs a tool call through a middleware stack. Like
    # AgentPipeline it *composes* a Pipeline rather than inheriting: the
    # definition block is instance_eval'd into the internal Pipeline, so `use`
    # / `run` inside it are the builder's methods. The tool's terminal app does
    # the work; middleware wraps it with concerns like file mutation queueing,
    # validation, logging.
    #
    # Coexists with Brute::Tools::* (which inherit from Brute::Tool). Use a
    # ToolPipeline when you want middleware; use Brute::Tool subclasses for
    # simple cases.
    #
    #   read = Brute::Turn::ToolPipeline.new(
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
    class ToolPipeline
      attr_reader :name, :description, :params

      def initialize(name:, description:, params: {}, &block)
        @name        = name.to_s
        @description = description
        @params      = params
        @pipeline    = Pipeline.new
        @pipeline.instance_eval(&block) if block
      end

      def call(events: Pipeline::NullSink.new, **arguments)
        env = {
          name:      @name,
          arguments: arguments,
          result:    nil,
          events:    events,
          metadata:  {},
        }
        @pipeline.call(env)
        env[:result]
      end

    end
  end
end

__END__

describe "brute/turn/tool_pipeline" do
  it "exposes name, description, params" do
    t = Brute::Turn::ToolPipeline.new(name: "echo", description: "echo input") do
      run ->(env) { env[:result] = env[:arguments][:msg] }
    end

    t.name.should == "echo"
    t.description.should == "echo input"
    t.call(msg: "hi").should == "hi"
  end

  it "passes arguments through env to the terminal app" do
    captured = nil
    t = Brute::Turn::ToolPipeline.new(name: "x", description: "x") do
      run ->(env) { captured = env[:arguments]; env[:result] = nil }
    end

    t.call(a: 1, b: 2)
    captured.should == { a: 1, b: 2 }
  end

  it "runs middleware around the terminal app (instance_eval'd block)" do
    wrap = Class.new do
      def initialize(app, tag:); @app = app; @tag = tag; end
      def call(env); (env[:metadata][:log] ||= []) << "in-#{@tag}"; @app.call(env); env[:metadata][:log] << "out-#{@tag}"; end
    end

    t = Brute::Turn::ToolPipeline.new(name: "x", description: "x") do
      use wrap, tag: "a"
      run ->(env) { env[:metadata][:log] << "core"; env[:result] = :ok }
    end

    t.call(input: 1).should == :ok
  end
end
