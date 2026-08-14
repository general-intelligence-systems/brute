# frozen_string_literal: true

require "brute"

module PrimeAgent
  module Middleware
    # Drives a Brute::PromptTemplate for the agent's system prompt.
    #
    # Brute::Middleware::SystemPrompt injects once (only when no system
    # message exists); this middleware re-renders the template on every
    # pass. Because the template's sections are procs re-evaluated per
    # render, the harness block, the skills listing, and even the template
    # file itself (re-read from disk) stay fresh mid-run — kernel-side
    # `harness.*` writes and refine edits appear on the next turn.
    #
    # Place INSIDE the turn loop:
    #
    #   .use(Brute::Middleware::Loop::ToolResult)
    #   .use(PrimeAgent::Middleware::PromptTemplate, prompt: system_prompt)
    class PromptTemplate
      def initialize(app, prompt:)
        @app = app
        @prompt = prompt
      end

      def call(env)
        refresh(env)
        @app.call(env)
      end

      private

      def refresh(env)
        content = @prompt.prepare(context(env)).to_s
        return if content.strip.empty?

        messages = env[:messages]
        index = messages.index { |message| message.role == :system }
        if index
          return if messages[index].content == content

          messages[index] = Brute::Message.new(role: :system, content: content)
        else
          messages.unshift(Brute::Message.new(role: :system, content: content))
        end
      end

      # Same ctx shape as Brute::Middleware::SystemPrompt#build_context.
      def context(env)
        {
          provider_name: env[:provider].to_s,
          model_name:    env[:model].to_s,
          cwd:           Dir.pwd,
        }.merge(env.fetch(:metadata, {}))
      end
    end
  end
end

__END__

require "brute/messages"

describe "prime_agent/middleware/prompt_template" do
  def middleware_for(prompt, app = ->(env) { env })
    PrimeAgent::Middleware::PromptTemplate.new(app, prompt: prompt)
  end

  it "injects the rendered system message when none exists" do
    prompt = Brute::PromptTemplate.new("You are <%= name %>.", name: "Pico")
    env = { messages: Brute.log }
    env[:messages].user("hi")
    middleware_for(prompt).call(env)

    env[:messages].first.role.should == :system
    env[:messages].first.content.should == "You are Pico."
  end

  it "re-renders procs on every pass and replaces the stale message" do
    tick = 0
    prompt = Brute::PromptTemplate.new("state: <%= tick %>", tick: -> { tick += 1 })
    middleware = middleware_for(prompt)
    env = { messages: Brute.log }

    middleware.call(env)
    env[:messages].first.content.should == "state: 1"
    middleware.call(env)
    env[:messages].first.content.should == "state: 2"
    env[:messages].size.should == 1 # replaced, not duplicated
  end

  it "keeps the message object when nothing changed" do
    prompt = Brute::PromptTemplate.new("static")
    middleware = middleware_for(prompt)
    env = { messages: Brute.log }

    middleware.call(env)
    first = env[:messages].first
    middleware.call(env)
    env[:messages].first.should.equal first
  end

  it "passes the turn ctx to arity-1 procs" do
    prompt = Brute::PromptTemplate.new("cwd: <%= cwd %>", cwd: ->(ctx) { ctx[:cwd] })
    env = { messages: Brute.log }
    middleware_for(prompt).call(env)
    env[:messages].first.content.should == "cwd: #{Dir.pwd}"
  end

  it "renders the example prompts/system.erb with its dynamic sections" do
    template = Brute::PromptTemplate.new(
      File.expand_path("../../../prompts/system.erb", __dir__),
      cwd: "/tmp/work",
      harness_state: -> { "HARNESS BLOCK HERE" },
      skills: -> { "SKILLS HERE" },
    )
    out = template.prepare.to_s
    out.should.include "You are a general purpose agent"
    out.should.include "Working directory: /tmp/work"
    out.should.include "IRuby is the agent's long-lived notebook"
    out.should.include "KernelAgent.spawn"
    out.should.include "HARNESS BLOCK HERE"
    out.should.include "SKILLS HERE"
  end

  it "omits the skills section when the skills proc returns nil" do
    template = Brute::PromptTemplate.new(
      File.expand_path("../../../prompts/system.erb", __dir__),
      cwd: "/tmp/work",
      harness_state: -> { "H" },
      skills: -> { nil },
    )
    out = template.prepare.to_s
    out.should.include "H"
    out.should.not.include "nil"
  end
end
