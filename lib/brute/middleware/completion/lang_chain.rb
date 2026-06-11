# frozen_string_literal: true

require "bundler/setup"
require "brute"
require_relative "base"

module Brute
  module Middleware
    module Completion
      # Completion backed by the langchainrb gem
      # (https://github.com/patterns-ai-core/langchainrb).
      #
      # The gem is an optional dependency — install it with
      # `bundle config set --local with completions && bundle install`.
      # langchainrb's LLM classes wrap many providers; build one and hand
      # it over:
      #
      #   run Brute::Middleware::Completion::LangChain.new(
      #     llm: Langchain::LLM::OpenAI.new(api_key: ENV["OPENAI_API_KEY"]),
      #   )
      #
      # Options:
      #
      #   llm:         a Langchain::LLM instance (required; client: is an alias)
      #   model:       model id override (falls back to env[:model], then the
      #                llm instance's default)
      #   tools:       tools list, any shape Tools::Adapter accepts
      #   temperature: sampling temperature (default 0.7)
      #
      class LangChain < Base
        private

          def complete(env)
            require_backend!("langchainrb", "langchain")

            params = {
              messages:    openai_messages(env[:messages]),
              temperature: temperature(env),
            }
            tools = openai_tool_definitions(env)
            params[:tools] = tools if tools.any?
            model = option(env, :model)
            params[:model] = model if model

            response = llm.chat(**params)
            emit_content(env, response.chat_completion)
            message_from_openai(
              "content"    => response.chat_completion,
              "tool_calls" => response.tool_calls,
            )
          end

          def llm
            options[:llm] || options[:client] ||
              raise(ArgumentError,
                    "#{self.class.name} needs an llm: option, e.g. " \
                    "Langchain::LLM::OpenAI.new(api_key: ENV[\"OPENAI_API_KEY\"])")
          end
      end
    end
  end
end

test do
  require "brute/session"

  langchain_available = begin
    require "langchain"
    true
  rescue LoadError
    false
  end

  if langchain_available
    fake_response = Class.new do
      def initialize(content, tool_calls = [])
        @content = content
        @tool_calls = tool_calls
      end

      def chat_completion
        @content
      end

      def tool_calls
        @tool_calls
      end
    end

    fake_llm = Class.new do
      attr_reader :calls

      def initialize(response)
        @response = response
        @calls = []
      end

      def chat(**params)
        @calls << params
        @response
      end
    end

    it "appends the response as a RubyLLM assistant message" do
      llm = fake_llm.new(fake_response.new("via langchain"))
      mw = Brute::Middleware::Completion::LangChain.new(llm: llm)

      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("hi")
      mw.call(env)

      env[:messages].last.should.be.kind_of?(::RubyLLM::Message)
      env[:messages].last.content.should == "via langchain"
      env[:events].should == [{ type: :content, data: "via langchain" }]
    end

    it "sends the session in OpenAI wire format with model and tools" do
      llm = fake_llm.new(fake_response.new("ok"))
      inline_tool = { name: "echo", description: "Echo", execute: ->(**) { "ok" } }
      mw = Brute::Middleware::Completion::LangChain.new(llm: llm, model: "gpt-4o-mini", tools: [inline_tool])

      env = { messages: Brute::Session.new, events: [] }
      env[:messages].user("hello")
      mw.call(env)

      call = llm.calls.first
      call[:messages].should == [{ role: "user", content: "hello" }]
      call[:model].should == "gpt-4o-mini"
      call[:tools].first[:function][:name].should == "echo"
    end

    it "converts langchain tool calls into RubyLLM tool calls" do
      llm = fake_llm.new(fake_response.new(nil, [
        { "id" => "call_9", "type" => "function", "function" => { "name" => "echo", "arguments" => "{\"msg\":\"hi\"}" } },
      ]))
      mw = Brute::Middleware::Completion::LangChain.new(llm: llm)

      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("go")
      mw.call(env)

      tool_calls = env[:messages].last.tool_calls
      tool_calls.keys.should == ["call_9"]
      tool_calls["call_9"].name.should == "echo"
      tool_calls["call_9"].arguments.should == { "msg" => "hi" }
    end

    it "raises ArgumentError without an llm" do
      mw = Brute::Middleware::Completion::LangChain.new
      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("hi")
      lambda { mw.call(env) }.should.raise(ArgumentError)
    end
  else
    it "raises MissingDependency when langchainrb is not installed" do
      mw = Brute::Middleware::Completion::LangChain.new
      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("hi")
      lambda { mw.call(env) }.should.raise(Brute::Middleware::Completion::MissingDependency)
    end
  end
end
