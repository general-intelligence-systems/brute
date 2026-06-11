# frozen_string_literal: true

require "bundler/setup"
require "brute"
require_relative "base"

module Brute
  module Middleware
    module Completion
      # Completion backed by the ruby_llm gem (Brute's default). Calls the
      # LLM with the current conversation, appends the response to the
      # session, and fires events along the way.
      #
      # Configuration happens at point of use and falls back to env for
      # anything not given, so an Agent's provider/model/tools still flow
      # through when the middleware is used bare:
      #
      #   Brute::Agent.new(provider: :ollama, model: "llama3.2:latest") do
      #     use Brute::Middleware::ToolCall
      #     run Brute::Middleware::Completion::RubyLLM.new
      #   end
      #
      #   # or fully configured at point of use:
      #   run Brute::Middleware::Completion::RubyLLM.new(
      #     provider:    :ollama,
      #     model:       "llama3.2:latest",
      #     tools:       [],
      #     temperature: 0.7,
      #     streaming:   true,
      #   )
      #
      # Options:
      #
      #   provider:    LLM provider name (falls back to env[:provider])
      #   model:       model id (falls back to env[:model])
      #   tools:       tools list, any shape Tools::Adapter accepts
      #   temperature: sampling temperature (default 0.7)
      #   streaming:   stream chunks as :content / :reasoning events
      #   client:      injectable completion client (tests, custom transports);
      #                anything responding to complete(messages, **kwargs)
      #
      class RubyLLM < Base
        private

          def complete(env)
            provider = option(env, :provider)

            kwargs = {
              model:       resolve_model(option(env, :model), provider),
              tools:       tool_adapters(env).transform_values(&:to_ruby_llm),
              temperature: temperature(env),
            }

            provider_client = client(provider)

            if streaming?(env)
              provider_client.complete(env[:messages], **kwargs) do |chunk|
                if chunk.content && !chunk.content.to_s.empty?
                  env[:events] << { type: :content, data: chunk.content.to_s }
                end

                if chunk.respond_to?(:thinking) && chunk.thinking&.respond_to?(:text) && chunk.thinking.text
                  env[:events] << { type: :reasoning, data: chunk.thinking.text }
                end
              end
            else
              provider_client.complete(env[:messages], **kwargs).then do |response|
                emit_content(env, response.content)
                response
              end
            end
          end

          def client(provider)
            options[:client] || ::RubyLLM::Provider.resolve(provider).new(Brute.config)
          end

          # Look the model up in ruby_llm's registry; fall back to the raw
          # id for models the registry doesn't know (custom endpoints,
          # injected clients).
          def resolve_model(model, provider)
            ::RubyLLM.models.find(model, provider)
          rescue StandardError
            model
          end

          def streaming?(env)
            options.fetch(:streaming) { env[:streaming] } == true
          end
      end
    end
  end
end

test do
  require "brute/session"

  fake_client = Class.new do
    attr_reader :calls

    def initialize(response_content = "mock response")
      @response_content = response_content
      @calls = []
    end

    def complete(messages, **kwargs)
      @calls << { messages: messages.dup, kwargs: kwargs }
      ::RubyLLM::Message.new(role: :assistant, content: @response_content)
    end
  end

  it "appends the LLM response to the session" do
    client = fake_client.new("hello there")
    mw = Brute::Middleware::Completion::RubyLLM.new(client: client, model: "test-model")

    env = { messages: Brute::Session.new, provider: :stub, tools: [], events: [] }
    env[:messages].user("hi")
    mw.call(env)

    env[:messages].last.role.should == :assistant
    env[:messages].last.content.should == "hello there"
  end

  it "fires a content event for non-streaming responses" do
    client = fake_client.new("announce me")
    mw = Brute::Middleware::Completion::RubyLLM.new(client: client, model: "test-model")

    env = { messages: Brute::Session.new, provider: :stub, tools: [], events: [] }
    env[:messages].user("hi")
    mw.call(env)

    env[:events].should == [{ type: :content, data: "announce me" }]
  end

  it "prefers point-of-use options over env" do
    client = fake_client.new
    mw = Brute::Middleware::Completion::RubyLLM.new(
      client:      client,
      model:       "use-this-model",
      temperature: 0.1,
    )

    env = { messages: Brute::Session.new, provider: :stub, model: "env-model", tools: [], events: [] }
    env[:messages].user("hi")
    mw.call(env)

    client.calls.first[:kwargs][:model].should == "use-this-model"
    client.calls.first[:kwargs][:temperature].should == 0.1
  end

  it "falls back to env for unset options" do
    client = fake_client.new
    mw = Brute::Middleware::Completion::RubyLLM.new(client: client)

    env = { messages: Brute::Session.new, provider: :stub, model: "env-model", tools: [], events: [] }
    env[:messages].user("hi")
    mw.call(env)

    client.calls.first[:kwargs][:model].should == "env-model"
    client.calls.first[:kwargs][:temperature].should == 0.7
  end

  it "passes tools through the adapter as ruby_llm tools" do
    client = fake_client.new
    inline_tool = { name: "echo", description: "Echo", execute: ->(**) { "ok" } }
    mw = Brute::Middleware::Completion::RubyLLM.new(client: client, model: "m", tools: [inline_tool])

    env = { messages: Brute::Session.new, provider: :stub, events: [] }
    env[:messages].user("hi")
    mw.call(env)

    tools = client.calls.first[:kwargs][:tools]
    tools.keys.should == [:echo]
    tools[:echo].should.be.kind_of?(::RubyLLM::Tool)
  end

  it "works as a `use` middleware, calling the inner app after completing" do
    client = fake_client.new
    called = false
    inner  = ->(env) { called = true }
    mw = Brute::Middleware::Completion::RubyLLM.new(inner, client: client, model: "m")

    env = { messages: Brute::Session.new, provider: :stub, tools: [], events: [] }
    env[:messages].user("hi")
    mw.call(env)

    called.should.be.true
  end
end
