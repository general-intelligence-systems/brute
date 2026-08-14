# frozen_string_literal: true

require "brute"

require_relative "../harness_format"

module PrimeAgent
  module Middleware
    # Stage 2 — continual harness state in the prompt.
    #
    # Appends the "# Continual Harness State" block to the system message
    # and keeps it fresh: every pass recomputes the block from the harness
    # (file mtime sync makes kernel-side `harness.*` writes and host-side
    # refine edits visible on the next turn). This is the analogue of
    # prime-agent rebuilding its system prompt from the harness state
    # (agent-session.ts _rebuildSystemPrompt), rendered continuously.
    #
    # Place INSIDE the turn loop so each iteration re-renders:
    #
    #   .use(Brute::Middleware::Loop::ToolResult)
    #   .use(PrimeAgent::Middleware::HarnessPrompt, harness: harness)
    class HarnessPrompt
      MARKER = "# Continual Harness State"

      def initialize(app, harness:)
        @app = app
        @harness = harness
        @base = nil
      end

      def call(env)
        refresh(env)
        @app.call(env)
      end

      private

      def refresh(env)
        messages = env[:messages]
        index = messages.index { |message| message.role == :system }
        return unless index

        current = messages[index].content.to_s
        @base ||= current.split("\n\n#{MARKER}").first
        content = "#{@base}\n\n#{HarnessFormat.format_harness_state_for_prompt(@harness.merged_state)}"
        return if content == current

        messages[index] = Brute::Message.new(role: :system, content: content)
      end
    end
  end
end

__END__

require "brute/messages"
require "tmpdir"

describe "prime_agent/middleware/harness_prompt" do
  def build_harness
    Dir.mktmpdir do |local_dir|
      Dir.mktmpdir do |global_dir|
        harness = PrimeAgent::Harness.new(
          local_store: PrimeAgent::HarnessStore.new(local_dir, scope: "local"),
          global_store: PrimeAgent::HarnessStore.new(global_dir, scope: "global"),
        )
        yield harness
      end
    end
  end

  def middleware_for(harness, app = ->(env) { env })
    PrimeAgent::Middleware::HarnessPrompt.new(app, harness: harness)
  end

  it "appends the harness block to the system message" do
    build_harness do |harness|
      env = { messages: Brute.log }
      env[:messages].system("You are a test agent.")
      middleware_for(harness).call(env)

      content = env[:messages].first.content
      content.should.start_with "You are a test agent."
      content.should.include "# Continual Harness State"
      content.should.include "No saved harness entries yet."
    end
  end

  it "is idempotent — one block, refreshed not duplicated" do
    build_harness do |harness|
      middleware = middleware_for(harness)
      env = { messages: Brute.log }
      env[:messages].system("Base prompt.")

      middleware.call(env)
      middleware.call(env)
      content = env[:messages].first.content
      content.scan("# Continual Harness State").size.should == 1
      content.should.start_with "Base prompt."
    end
  end

  it "reflects harness writes on the next pass" do
    build_harness do |harness|
      middleware = middleware_for(harness)
      env = { messages: Brute.log }
      env[:messages].system("Base prompt.")

      middleware.call(env)
      env[:messages].first.content.should.include "No saved harness entries yet."

      harness.create_memory("Deploy command", "bin/deploy --production")
      middleware.call(env)
      content = env[:messages].first.content
      content.should.include "[local:deploy_command] Deploy command"
      content.should.not.include "No saved harness entries yet."
    end
  end

  it "is a no-op when there is no system message" do
    build_harness do |harness|
      env = { messages: Brute.log }
      env[:messages].user("hi")
      middleware_for(harness).call(env)
      env[:messages].size.should == 1
    end
  end
end
