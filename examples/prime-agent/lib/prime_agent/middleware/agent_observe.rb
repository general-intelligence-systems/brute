# frozen_string_literal: true

require_relative "../agent_family"

module PrimeAgent
  module Middleware
    # AgentObserve — per-turn middleware (just inside AgentMessages). The
    # read-model half of prime-agent's agent-observe feature
    # (core/agent-observe.ts): upstream reads the target session's in-memory
    # transcript through the daemon; here each agent's pipeline publishes a
    # transcript snapshot to <bus_dir>/<id>-transcript.json after every turn,
    # and the kernel's `agent_observe` proxy reads those files (clamping
    # previews at read time, per upstream's 1-50 / 80-2000 bounds).
    #
    # Message contents are stored capped at 2100 chars — observe previews
    # clamp to at most 2000 at read time, so nothing larger is ever shown.
    #
    # Loaded host-side AND into the IRuby kernel (children publish their
    # transcripts from there): keep it dependency-free.
    class AgentObserve
      MAX_STORED_CHARS = 2100

      def initialize(app, bus_dir:, agent_id:)
        @app = app
        @bus_dir = bus_dir
        @agent_id = agent_id
      end

      def call(env)
        @app.call(env)
        publish(env)
        env
      rescue StandardError
        publish(env) # a failed turn still publishes what happened
        raise
      end

      private

      def publish(env)
        FileUtils.mkdir_p(@bus_dir)
        snapshot = env[:messages].map do |message|
          entry = { "role" => message.role.to_s, "content" => truncate(message.content.to_s) }
          calls = Array(message.tool_calls).map(&:name)
          entry["tool_calls"] = calls unless calls.empty?
          entry
        end
        path = PrimeAgent::AgentFamily.transcript_path(@bus_dir, @agent_id)
        tmp = "#{path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(snapshot)}\n")
        File.rename(tmp, path)
      rescue StandardError
        nil # observation must never break a turn
      end

      def truncate(content)
        return content if content.length <= MAX_STORED_CHARS

        "#{content[0...MAX_STORED_CHARS]}\n[... #{content.length - MAX_STORED_CHARS} more characters truncated]"
      end
    end
  end
end

__END__

describe "prime_agent/middleware/agent_observe" do
  require "brute/messages"
  require "json"
  require "tmpdir"

  it "publishes the transcript snapshot after each turn" do
    Dir.mktmpdir do |dir|
      app = lambda do |env|
        env[:messages] << Brute::Message.new(role: :assistant, content: "working", tool_calls: [
          { id: "t1", name: "iruby", arguments: { "code" => "1" } },
        ])
        env
      end
      env = { messages: Brute.log }
      env[:messages].user("task")
      PrimeAgent::Middleware::AgentObserve.new(app, bus_dir: dir, agent_id: "ka_1").call(env)

      transcript = JSON.parse(File.read(PrimeAgent::AgentFamily.transcript_path(dir, "ka_1")))
      transcript.map { |m| m["role"] }.should == %w[user assistant]
      transcript.last["tool_calls"].should == ["iruby"]
    end
  end

  it "caps stored message contents" do
    Dir.mktmpdir do |dir|
      app = ->(env) { env[:messages].assistant("x" * 5000); env }
      env = { messages: Brute.log }
      PrimeAgent::Middleware::AgentObserve.new(app, bus_dir: dir, agent_id: "ka_2").call(env)
      content = JSON.parse(File.read(PrimeAgent::AgentFamily.transcript_path(dir, "ka_2"))).last["content"]
      content.length.should.be < 2200
      content.should.include "more characters truncated"
    end
  end
end
