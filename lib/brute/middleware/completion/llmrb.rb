# frozen_string_literal: true

require "bundler/setup"
require "brute"
require_relative "base"

module Brute
  module Middleware
    module Completion
      # Completion backed by the llm.rb gem (https://github.com/llmrb/llm.rb).
      #
      # The gem is an optional dependency — install it with
      # `bundle config set --local with completions && bundle install`.
      #
      #   run Brute::Middleware::Completion::LLMrb.new(
      #     provider:         :openai,
      #     provider_options: { key: ENV["OPENAI_API_KEY"] },
      #     model:            "gpt-4o-mini",
      #   )
      #
      #   # or hand over a fully configured llm.rb provider:
      #   run Brute::Middleware::Completion::LLMrb.new(
      #     client: LLM.ollama(key: nil),
      #     model:  "llama3.2:latest",
      #   )
      #
      # Options:
      #
      #   client:           an LLM::Provider instance (takes precedence)
      #   provider:         llm.rb constructor name (:openai, :anthropic,
      #                     :ollama, :gemini → :google, ...); falls back to
      #                     env[:provider]
      #   provider_options: kwargs for the constructor (e.g. { key: "..." })
      #   model:            model id (falls back to env[:model])
      #   tools:            tools list, any shape Tools::Adapter accepts
      #   temperature:      sampling temperature (default 0.7)
      #
      class LLMrb < Base
        private

          def complete(env)
            require_backend!("llm.rb", "llm")

            session = env[:messages]
            history = session[0...-1].map { |m| llmrb_message(m) }
            prompt  = llmrb_message(session.last)

            params = {
              role:        prompt.role,
              model:       option(env, :model),
              messages:    history,
              temperature: temperature(env),
            }.compact
            functions = llmrb_functions(env)
            params[:tools] = functions if functions.any?

            response = client(env).complete(prompt.content, params)
            message_from_llmrb(env, response)
          end

          def client(env)
            options[:client] ||= begin
              provider = option(env, :provider) or
                raise ArgumentError, "#{self.class.name} needs a client: or provider: option"
              ::LLM.public_send(provider, **(options[:provider_options] || {}))
            end
          end

          def llmrb_message(message)
            if message.tool_call?
              calls = message.tool_calls.values
              ::LLM::Message.new("assistant", message.content.to_s, {
                tool_calls:          calls.map { |tc| { id: tc.id, name: tc.name, arguments: tc.arguments } },
                original_tool_calls: calls.map { |tc| openai_tool_call(tc) },
              })
            elsif message.role == :tool
              ::LLM::Message.new(
                "tool",
                [::LLM::Function::Return.new(message.tool_call_id, nil, message.content.to_s)],
              )
            else
              ::LLM::Message.new(message.role.to_s, message.content.to_s)
            end
          end

          def llmrb_functions(env)
            tool_adapters(env).values.map do |adapter|
              schema = adapter.to_h[:parameters]
              ::LLM.function(adapter.name) do |fn|
                fn.description adapter.description
                fn.params { schema }
                fn.define { |**args| adapter.call(args) }
              end
            end
          end

          def message_from_llmrb(env, response)
            choice = response.choices.first
            emit_content(env, choice.content)

            tool_calls = Array(choice.extra[:tool_calls]).each_with_object({}) do |tc, hash|
              tc = tc.to_h
              id = field(tc, :id)
              hash[id] = ::RubyLLM::ToolCall.new(
                id:        id,
                name:      field(tc, :name),
                arguments: field(tc, :arguments).to_h,
              )
            end

            ::RubyLLM::Message.new(
              role:       :assistant,
              content:    choice.content,
              tool_calls: tool_calls.empty? ? nil : tool_calls,
            )
          end
      end
    end
  end
end

test do
  require "brute/session"

  llmrb_available = begin
    require "llm"
    true
  rescue LoadError
    false
  end

  if llmrb_available
    fake_response = Class.new do
      def initialize(message)
        @message = message
      end

      def choices
        [@message]
      end
    end

    fake_client = Class.new do
      attr_reader :calls

      def initialize(response)
        @response = response
        @calls = []
      end

      def complete(prompt, params = {})
        @calls << { prompt: prompt, params: params }
        @response
      end
    end

    it "appends the response as a RubyLLM assistant message" do
      response = fake_response.new(::LLM::Message.new("assistant", "from llm.rb", { tool_calls: [] }))
      client = fake_client.new(response)
      mw = Brute::Middleware::Completion::LLMrb.new(client: client, model: "m")

      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("hi")
      mw.call(env)

      env[:messages].last.should.be.kind_of?(::RubyLLM::Message)
      env[:messages].last.role.should == :assistant
      env[:messages].last.content.should == "from llm.rb"
      env[:events].should == [{ type: :content, data: "from llm.rb" }]
    end

    it "sends prior messages as history and the last as the prompt" do
      response = fake_response.new(::LLM::Message.new("assistant", "ok", { tool_calls: [] }))
      client = fake_client.new(response)
      mw = Brute::Middleware::Completion::LLMrb.new(client: client, model: "m")

      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("first")
      env[:messages].assistant("second")
      env[:messages].user("third")
      mw.call(env)

      call = client.calls.first
      call[:prompt].should == "third"
      call[:params][:messages].map(&:content).should == ["first", "second"]
      call[:params][:model].should == "m"
    end

    it "converts llm.rb tool calls into RubyLLM tool calls" do
      message = ::LLM::Message.new("assistant", nil, {
        tool_calls: [{ id: "call_1", name: "echo", arguments: { "msg" => "hi" } }],
      })
      client = fake_client.new(fake_response.new(message))
      mw = Brute::Middleware::Completion::LLMrb.new(client: client, model: "m")

      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("go")
      mw.call(env)

      tool_calls = env[:messages].last.tool_calls
      tool_calls.keys.should == ["call_1"]
      tool_calls["call_1"].name.should == "echo"
      tool_calls["call_1"].arguments.should == { "msg" => "hi" }
    end

    it "advertises adapted tools as LLM::Function objects" do
      response = fake_response.new(::LLM::Message.new("assistant", "ok", { tool_calls: [] }))
      client = fake_client.new(response)
      inline_tool = { name: "echo", description: "Echo", execute: ->(**) { "ok" } }
      mw = Brute::Middleware::Completion::LLMrb.new(client: client, model: "m", tools: [inline_tool])

      env = { messages: Brute::Session.new, events: [] }
      env[:messages].user("go")
      mw.call(env)

      functions = client.calls.first[:params][:tools]
      functions.size.should == 1
      functions.first.should.be.kind_of?(::LLM::Function)
      functions.first.name.should == "echo"
    end
  else
    it "raises MissingDependency when llm.rb is not installed" do
      mw = Brute::Middleware::Completion::LLMrb.new(model: "m")
      env = { messages: Brute::Session.new, tools: [], events: [] }
      env[:messages].user("hi")
      lambda { mw.call(env) }.should.raise(Brute::Middleware::Completion::MissingDependency)
    end
  end
end
