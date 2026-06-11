# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"

module Brute
  module Middleware
    # Completion middlewares are the terminal app of an agent pipeline:
    # each one calls an LLM through a different Ruby library and appends
    # the response to the session as a RubyLLM::Message (Brute's internal
    # message format).
    #
    # Pick one per agent, configured at point of use:
    #
    #   run Brute::Middleware::Completion::RubyLLM.new(provider: :ollama, model: "llama3.2:latest")
    #   run Brute::Middleware::Completion::LLMrb.new(provider: :openai, provider_options: {key: ENV["OPENAI_API_KEY"]})
    #   run Brute::Middleware::Completion::OpenRouter.new(model: "anthropic/claude-sonnet-4")
    #   run Brute::Middleware::Completion::LangChain.new(llm: Langchain::LLM::OpenAI.new(api_key: ENV["OPENAI_API_KEY"]))
    #
    # Anything not configured falls back to env, so an Agent's
    # provider/model/tools still flow through.
    module Completion
      # Raised when a completion middleware's backing gem isn't installed.
      class MissingDependency < StandardError; end

      # Shared machinery: option/env fallback, session append, and message
      # conversions. Subclasses implement #complete(env) returning a
      # RubyLLM::Message.
      class Base
        def initialize(app = nil, opts = {}, **kwopts)
          @app     = app
          @options = opts.merge(kwopts)
        end

        def call(env)
          env[:messages] << complete(env)
          @app&.call(env)
          env
        end

        private

          attr_reader :options

          def complete(env)
            raise NotImplementedError, "#{self.class} must implement #complete(env)"
          end

          # Point-of-use option, falling back to env.
          def option(env, key)
            @options.fetch(key) { env[key] }
          end

          def temperature(env)
            @options.fetch(:temperature) { env.fetch(:temperature, 0.7) }
          end

          def tool_adapters(env)
            Brute::Tools::Adapter.wrap_all(option(env, :tools) || [])
          end

          def emit_content(env, content)
            env[:events] << { type: :content, data: content.to_s } unless content.to_s.empty?
          end

          def require_backend!(gem_name, require_path = gem_name)
            require require_path
          rescue LoadError
            raise MissingDependency,
                  "#{self.class.name} needs the '#{gem_name}' gem. Install it with " \
                  "`bundle config set --local with completions && bundle install` " \
                  "or add `gem \"#{gem_name}\"` to your Gemfile."
          end

          # === OpenAI-style wire format ===
          #
          # The lingua franca of LLM HTTP APIs — used by the OpenRouter and
          # LangChain backends, and by any future backend that talks
          # OpenAI-compatible JSON.

          def openai_messages(session)
            session.map { |message| openai_message(message) }
          end

          def openai_message(message)
            if message.tool_call?
              {
                role:       "assistant",
                content:    message.content.to_s,
                tool_calls: message.tool_calls.values.map { |tc| openai_tool_call(tc) },
              }
            elsif message.role == :tool
              { role: "tool", tool_call_id: message.tool_call_id, content: message.content.to_s }
            else
              { role: message.role.to_s, content: message.content.to_s }
            end
          end

          def openai_tool_call(tool_call)
            {
              id:   tool_call.id,
              type: "function",
              function: {
                name:      tool_call.name,
                arguments: JSON.generate(tool_call.arguments || {}),
              },
            }
          end

          def openai_tool_definitions(env)
            tool_adapters(env).values.map { |adapter| { type: "function", function: adapter.to_h } }
          end

          # Build the session message from an OpenAI-style response message
          # ({"role" => "assistant", "content" => ..., "tool_calls" => [...]}).
          # Handles string and symbol keys.
          def message_from_openai(message_hash)
            message_hash ||= {}
            content    = field(message_hash, :content)
            tool_calls = Array(field(message_hash, :tool_calls)).each_with_object({}) do |tc, hash|
              id       = field(tc, :id)
              function = field(tc, :function) || {}
              hash[id] = ::RubyLLM::ToolCall.new(
                id:        id,
                name:      field(function, :name),
                arguments: parse_arguments(field(function, :arguments)),
              )
            end

            ::RubyLLM::Message.new(
              role:       :assistant,
              content:    content,
              tool_calls: tool_calls.empty? ? nil : tool_calls,
            )
          end

          def field(hash, key)
            hash[key.to_s] || hash[key.to_sym]
          end

          def parse_arguments(arguments)
            return arguments.to_h if arguments.respond_to?(:to_h) && !arguments.is_a?(String)

            JSON.parse(arguments.to_s)
          rescue JSON::ParserError
            {}
          end
      end
    end
  end
end

test do
  require "brute/session"

  it "raises NotImplementedError without a #complete implementation" do
    env = { messages: Brute::Session.new, events: [] }
    lambda { Brute::Middleware::Completion::Base.new.call(env) }.should.raise(NotImplementedError)
  end

  it "appends the subclass response and calls the inner app" do
    subclass = Class.new(Brute::Middleware::Completion::Base) do
      def complete(_env)
        ::RubyLLM::Message.new(role: :assistant, content: "from subclass")
      end
    end

    called = false
    mw = subclass.new(->(_env) { called = true })
    env = { messages: Brute::Session.new, events: [] }
    mw.call(env)

    env[:messages].last.content.should == "from subclass"
    called.should.be.true
  end
end
