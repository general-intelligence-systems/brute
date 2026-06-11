# frozen_string_literal: true

require "bundler/setup"
require "brute"
require_relative "base"

module Brute
  module Middleware
    module Completion
      # Completion backed by the open_router gem
      # (https://github.com/OlympiaAI/open_router).
      #
      # The gem is an optional dependency — install it with
      # `bundle config set --local with completions && bundle install`.
      #
      #   run Brute::Middleware::Completion::OpenRouter.new(
      #     model:        "anthropic/claude-sonnet-4",
      #     access_token: ENV["OPENROUTER_API_KEY"],   # default
      #   )
      #
      # Options:
      #
      #   client:       an OpenRouter::Client instance (takes precedence)
      #   access_token: OpenRouter API key (default ENV["OPENROUTER_API_KEY"])
      #   model:        model id, or array of ids for fallback routing
      #                 (falls back to env[:model], then "openrouter/auto")
      #   providers:    optional provider priority list
      #   transforms:   optional OpenRouter prompt transforms
      #   extras:       extra request parameters merged into the payload
      #   tools:        tools list, any shape Tools::Adapter accepts
      #   temperature:  sampling temperature (default 0.7)
      #
      class OpenRouter < Base
        private

          def complete(env)
            require_backend!("open_router")

            extras = { temperature: temperature(env) }
            tools  = openai_tool_definitions(env)
            extras[:tools] = tools if tools.any?
            extras.merge!(options[:extras] || {})

            response = client.complete(
              openai_messages(env[:messages]),
              model:      option(env, :model) || "openrouter/auto",
              providers:  options[:providers] || [],
              transforms: options[:transforms] || [],
              extras:     extras,
            )

            message = response.dig("choices", 0, "message")
            emit_content(env, field(message || {}, :content))
            message_from_openai(message)
          end

          def client
            options[:client] ||= ::OpenRouter::Client.new(
              access_token: options.fetch(:access_token) { ENV.fetch("OPENROUTER_API_KEY") },
            )
          end
      end
    end
  end
end

test do
  require "brute/session"

  open_router_available = begin
    require "open_router"
    true
  rescue LoadError
    false
  end

  if open_router_available
    fake_client = Class.new do
      attr_reader :calls

      def initialize(response)
        @response = response
        @calls = []
      end

      def complete(messages, **kwargs)
        @calls << { messages: messages, kwargs: kwargs }
        @response
      end
    end

    assistant_response = lambda do |message|
      { "choices" => [{ "message" => message }] }
    end

    it "appends the response as a RubyLLM assistant message" do
      client = fake_client.new(assistant_response.call("role" => "assistant", "content" => "via openrouter"))
      mw = Brute::Middleware::Completion::OpenRouter.new(client: client, model: "test/model")

      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("hi")
      mw.call(env)

      env[:messages].last.should.be.kind_of?(::RubyLLM::Message)
      env[:messages].last.content.should == "via openrouter"
      env[:events].should == [{ type: :content, data: "via openrouter" }]
    end

    it "sends the session in OpenAI wire format" do
      client = fake_client.new(assistant_response.call("role" => "assistant", "content" => "ok"))
      mw = Brute::Middleware::Completion::OpenRouter.new(client: client, model: "test/model")

      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("question")
      env[:messages].assistant("answer")
      env[:messages].user("follow-up")
      mw.call(env)

      client.calls.first[:messages].should == [
        { role: "user", content: "question" },
        { role: "assistant", content: "answer" },
        { role: "user", content: "follow-up" },
      ]
      client.calls.first[:kwargs][:model].should == "test/model"
    end

    it "round-trips tool calls and tool results" do
      tool_calls = {
        "call_1" => ::RubyLLM::ToolCall.new(id: "call_1", name: "echo", arguments: { "msg" => "hi" }),
      }
      client = fake_client.new(assistant_response.call(
        "role"       => "assistant",
        "content"    => nil,
        "tool_calls" => [
          { "id" => "call_2", "type" => "function", "function" => { "name" => "echo", "arguments" => "{\"msg\":\"again\"}" } },
        ],
      ))
      mw = Brute::Middleware::Completion::OpenRouter.new(client: client, model: "test/model")

      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("go")
      env[:messages] << ::RubyLLM::Message.new(role: :assistant, content: "", tool_calls: tool_calls)
      env[:messages] << ::RubyLLM::Message.new(role: :tool, content: "echoed: hi", tool_call_id: "call_1")
      mw.call(env)

      sent = client.calls.first[:messages]
      sent[1][:tool_calls].first[:function][:name].should == "echo"
      sent[2].should == { role: "tool", tool_call_id: "call_1", content: "echoed: hi" }

      received = env[:messages].last.tool_calls
      received.keys.should == ["call_2"]
      received["call_2"].arguments.should == { "msg" => "again" }
    end

    it "advertises adapted tools as OpenAI function definitions" do
      client = fake_client.new(assistant_response.call("role" => "assistant", "content" => "ok"))
      inline_tool = {
        name:        "adder",
        description: "Add",
        params:      { a: { type: "number", required: true } },
        execute:     ->(a:) { a },
      }
      mw = Brute::Middleware::Completion::OpenRouter.new(client: client, model: "m", tools: [inline_tool])

      env = { messages: Brute::Session.new, events: [] }
      env[:messages].user("go")
      mw.call(env)

      tools = client.calls.first[:kwargs][:extras][:tools]
      tools.first[:type].should == "function"
      tools.first[:function][:name].should == "adder"
      tools.first[:function][:parameters][:required].should == ["a"]
    end
  else
    it "raises MissingDependency when open_router is not installed" do
      mw = Brute::Middleware::Completion::OpenRouter.new(model: "m")
      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("hi")
      lambda { mw.call(env) }.should.raise(Brute::Middleware::Completion::MissingDependency)
    end
  end
end
