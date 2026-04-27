# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Prepends a system message to env[:messages] before passing control
    # down the middleware chain.
    #
    # By default, uses Brute::SystemPrompt.default which assembles a
    # provider-specific prompt stack (Identity, ToneAndStyle, ToolUsage,
    # etc.) from the Brute::Prompts modules and text files.
    #
    # Pass a custom Brute::SystemPrompt instance to override — useful
    # for SubAgents that need a specialized prompt (e.g. the explore
    # agent prompt):
    #
    #   use Brute::Middleware::SystemPrompt,
    #       system_prompt: Brute::SystemPrompt.build { |p, _ctx|
    #         p << Brute::Prompts.agent_prompt("explore")
    #       }
    #
    # Skips injection when env[:messages] already contains a :system
    # message (e.g. from session.system(...)), so manually-set system
    # prompts are respected.
    #
    class SystemPrompt
      def initialize(app, system_prompt: Brute::SystemPrompt.default)
        @app = app
        @system_prompt = system_prompt
      end

      def call(env)
        unless env[:messages].any? { |m| m.role == :system }
          ctx = build_context(env)
          result = @system_prompt.prepare(ctx)
          unless result.empty?
            env[:messages].unshift(
              RubyLLM::Message.new(role: :system, content: result.to_s)
            )
          end
        end

        @app.call(env)
      end

      private

        def build_context(env)
          {
            provider_name: env[:provider].to_s,
            model_name:    env[:model].to_s,
            cwd:           Dir.pwd,
          }.merge(env.fetch(:metadata, {}))
        end
    end
  end
end

test do
  require "brute/session"

  def build_middleware(system_prompt: Brute::SystemPrompt.default, &inner_block)
    inner = inner_block || ->(env) { env }
    Brute::Middleware::SystemPrompt.new(inner, system_prompt: system_prompt)
  end

  def base_env(messages: Brute::Session.new)
    {
      messages: messages,
      provider: :anthropic,
      model:    "claude-sonnet-4-20250514",
      metadata: {},
    }
  end

  it "prepends a system message when none exists" do
    mw = build_middleware
    env = base_env
    env[:messages].user("hi")

    mw.call(env)

    env[:messages].first.role.should == :system
  end

  it "skips injection when a system message already exists" do
    mw = build_middleware
    env = base_env
    env[:messages].system("custom prompt")
    env[:messages].user("hi")

    mw.call(env)

    env[:messages].select { |m| m.role == :system }.size.should == 1
    env[:messages].first.content.should == "custom prompt"
  end

  it "accepts a custom system_prompt" do
    custom = Brute::SystemPrompt.build { |p, _ctx| p << "You are a test agent." }
    mw = build_middleware(system_prompt: custom)
    env = base_env
    env[:messages].user("hi")

    mw.call(env)

    env[:messages].first.role.should == :system
    env[:messages].first.content.should == "You are a test agent."
  end

  it "merges metadata into context" do
    captured_ctx = nil
    spy_prompt = Brute::SystemPrompt.build do |p, ctx|
      captured_ctx = ctx
      p << "ok"
    end
    mw = build_middleware(system_prompt: spy_prompt)
    env = base_env
    env[:metadata][:agent] = "plan"
    env[:messages].user("hi")

    mw.call(env)

    captured_ctx[:agent].should == "plan"
    captured_ctx[:provider_name].should == "anthropic"
  end
end
