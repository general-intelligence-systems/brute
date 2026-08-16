# frozen_string_literal: true

require_relative "../agent_family"

module PrimeAgent
  module Middleware
    # AgentMessages — per-turn middleware (inside the continuation drivers,
    # just outside the loop). The delivery half of prime-agent's agent bus
    # (core/agent-messages.ts): drains this agent's mailbox and delivers each
    # pending message as a user message heading a fresh turn, looping until
    # the mailbox is empty at a turn boundary.
    #
    # The same class serves the root run (main.rb, agent_id "root") and every
    # KernelAgent child pipeline (kernel_agents.rb), because children are
    # threads inside the kernel and the mailbox is a file: sends from the
    # kernel's `agent_message.send` append to <bus_dir>/<id>-mailbox.jsonl and
    # land here at the recipient's next turn boundary (the port's follow_up
    # delivery — upstream's steer has no live-session analogue).
    #
    # Loaded host-side AND into the IRuby kernel (children build their
    # pipelines there): keep it dependency-free — Brute::Message is referenced
    # only at call time, after KernelAgents.ensure_loaded!.
    class AgentMessages
      def initialize(app, bus_dir:, agent_id:)
        @app = app
        @bus_dir = bus_dir
        @agent_id = agent_id
      end

      def call(env)
        @app.call(env)
        loop do
          drained = PrimeAgent::AgentFamily.drain_mailbox(@bus_dir, @agent_id)
          break if drained.empty?

          drained.each do |payload|
            env[:messages] << Brute::Message.new(role: :user, content: payload["prompt"].to_s)
          end
          @app.call(env)
        end
        env
      end
    end
  end
end

__END__

describe "prime_agent/middleware/agent_messages" do
  require "brute/messages"
  require "tmpdir"

  it "passes through once when the mailbox is empty" do
    Dir.mktmpdir do |dir|
      calls = 0
      app = ->(env) { calls += 1; env[:messages].assistant("ok"); env }
      env = { messages: Brute.log }
      env[:messages].user("task")
      PrimeAgent::Middleware::AgentMessages.new(app, bus_dir: dir, agent_id: "root").call(env)
      calls.should == 1
    end
  end

  it "delivers drained messages as user messages heading fresh turns" do
    Dir.mktmpdir do |dir|
      PrimeAgent::AgentFamily.deliver(dir, "root", { "prompt" => "msg one" })
      PrimeAgent::AgentFamily.deliver(dir, "root", { "prompt" => "msg two" })
      calls = 0
      app = lambda do |env|
        calls += 1
        if calls == 2
          # a message arriving mid-run is picked up at the next boundary
          PrimeAgent::AgentFamily.deliver(dir, "root", { "prompt" => "msg three" })
        end
        env[:messages].assistant("answer #{calls}")
        env
      end
      env = { messages: Brute.log }
      env[:messages].user("task")
      PrimeAgent::Middleware::AgentMessages.new(app, bus_dir: dir, agent_id: "root").call(env)

      calls.should == 3
      # the first turn's answer comes before the drained messages
      env[:messages][2].content.should == "msg one"
      env[:messages][3].content.should == "msg two"
      env[:messages][2].role.should == :user
      env[:messages].map(&:content).should.include "msg three"
      PrimeAgent::AgentFamily.pending_count(dir, "root").should == 0
    end
  end
end
