# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"
require "securerandom"
require "fileutils"

module Brute
  module Middleware
    # Durable execution for the tool loop. Where SessionLog persists the
    # conversation once per turn (outermost), Checkpoint snapshots it after
    # every pass through the inner stack — one checkpoint per LLM call + tool
    # execution. Place it just inside Loop::ToolResult:
    #
    #   use Brute::Middleware::Loop::ToolResult
    #   use Brute::Middleware::Checkpoint, path: "tmp/checkpoints.jsonl"
    #   use Brute::Middleware::MaxIterations
    #   use Brute::Middleware::DefaultToolPipeline, tools: Brute::Tools::ALL
    #
    # The store is just a JSONL log of snapshots — one line per checkpoint,
    # each carrying the full message log plus its own id and the id of the
    # parent checkpoint it grew from. That append-only chain buys three
    # things:
    #
    #   resume       pass resume: :latest — a crash mid-turn costs at most
    #                one iteration instead of the whole turn
    #   time travel  pass resume: "<checkpoint id>" — restart from any
    #                snapshot in the chain
    #   forking      checkpoints written after a time-travel resume carry the
    #                resumed id as parent_id, branching the chain in place
    #
    # System messages are not persisted (SystemPrompt re-adds them each
    # turn); restored history is inserted after any leading system message
    # and before the current turn's input.
    class Checkpoint < Brute::Middleware::Base
      def initialize(app, path:, resume: nil)
        @app    = app
        @path   = path
        @resume = resume
      end

      def call(env)
        restore(env) unless env[:metadata][:checkpoint]
        @app.call(env)
        persist(env)
        env
      end

      # Parsed checkpoint records (symbol keys, messages as plain hashes),
      # oldest first.
      def self.list(path)
        return [] unless path && File.exist?(path)

        File.foreach(path).filter_map do |line|
          line = line.strip
          JSON.parse(line, symbolize_names: true) unless line.empty?
        end
      end

      private

        def restore(env)
          env[:metadata][:checkpoint] = { path: @path }
          return unless @resume

          record = find_record
          if record.nil?
            return if @resume == :latest

            raise KeyError, "no checkpoint #{@resume.inspect} in #{@path}"
          end

          history = record[:messages].map { |h| Brute::Message.new(**h) }
          index = env[:messages].index { |m| m.role != :system } || env[:messages].size
          env[:messages].insert(index, *history)
          env[:metadata][:checkpoint][:id] = record[:id]
        end

        def find_record
          records = self.class.list(@path)
          @resume == :latest ? records.last : records.find { |r| r[:id] == @resume.to_s }
        end

        def persist(env)
          FileUtils.mkdir_p(File.dirname(@path))
          record = {
            id:        SecureRandom.hex(6),
            parent_id: env[:metadata][:checkpoint][:id],
            ts:        Time.now.utc.iso8601,
            iteration: env[:current_iteration],
            messages:  env[:messages].reject { |m| m.role == :system }.map(&:to_h),
          }
          File.open(@path, "a") { |f| f.puts(JSON.generate(record)) }
          env[:metadata][:checkpoint][:id] = record[:id]
        end
    end
  end
end

__END__

describe "brute/middleware/008_checkpoint" do
  require "brute/messages"
  require "tmpdir"

  it "snapshots after every pass through the loop" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cp.jsonl")
      calls = 0
      inner = ->(env) do
        calls += 1
        if calls < 3
          env[:messages] << Brute::Message.new(role: :tool, content: "r#{calls}", tool_call_id: "tc#{calls}")
        else
          env[:messages].assistant("done")
        end
      end

      stack = Brute::Middleware::Loop::ToolResult.new(
        Brute::Middleware::Checkpoint.new(inner, path: path)
      )
      env = { messages: Brute.log.tap { |l| l.user("go") }, metadata: {}, current_iteration: 1 }
      stack.call(env)

      records = Brute::Middleware::Checkpoint.list(path)
      records.size.should == 3
      records.map { |r| r[:iteration] }.should == [1, 2, 3]
      records.last[:messages].last[:content].should == "done"
    end
  end

  it "chains checkpoints via parent_id" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cp.jsonl")
      mw = Brute::Middleware::Checkpoint.new(->(env) { env[:messages].assistant("a") }, path: path)
      env = { messages: Brute.log.tap { |l| l.user("go") }, metadata: {}, current_iteration: 1 }
      mw.call(env)
      mw.call(env)

      records = Brute::Middleware::Checkpoint.list(path)
      records[0][:parent_id].should == nil
      records[1][:parent_id].should == records[0][:id]
    end
  end

  it "resume: :latest restores the conversation before this turn's input" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cp.jsonl")
      Brute::Middleware::Checkpoint.new(->(env) { env[:messages].assistant("first reply") }, path: path)
        .call({ messages: Brute.log.tap { |l| l.user("hi") }, metadata: {}, current_iteration: 1 })

      env = { messages: Brute.log.tap { |l| l.user("again") }, metadata: {}, current_iteration: 1 }
      Brute::Middleware::Checkpoint.new(->(_e) {}, path: path, resume: :latest).call(env)

      env[:messages].map(&:content).should == ["hi", "first reply", "again"]
    end
  end

  it "inserts restored history after the system message" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cp.jsonl")
      Brute::Middleware::Checkpoint.new(->(env) { env[:messages].assistant("old") }, path: path)
        .call({ messages: Brute.log.tap { |l| l.user("hi") }, metadata: {}, current_iteration: 1 })

      env = { messages: Brute.log, metadata: {}, current_iteration: 1 }
      env[:messages].system("rules")
      env[:messages].user("new input")
      Brute::Middleware::Checkpoint.new(->(_e) {}, path: path, resume: :latest).call(env)

      env[:messages].map(&:role).should == [:system, :user, :assistant, :user]
      env[:messages].last.content.should == "new input"
    end
  end

  it "resumes from a specific checkpoint id (time travel)" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cp.jsonl")
      mw = Brute::Middleware::Checkpoint.new(->(env) { env[:messages].assistant("reply #{env[:messages].size}") }, path: path)
      env = { messages: Brute.log.tap { |l| l.user("go") }, metadata: {}, current_iteration: 1 }
      mw.call(env)
      mw.call(env)

      first = Brute::Middleware::Checkpoint.list(path).first
      env2 = { messages: Brute.log, metadata: {}, current_iteration: 1 }
      Brute::Middleware::Checkpoint.new(->(_e) {}, path: path, resume: first[:id]).call(env2)

      env2[:messages].size.should == first[:messages].size
    end
  end

  it "forks: checkpoints after a time-travel resume carry the resumed id as parent" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cp.jsonl")
      mw = Brute::Middleware::Checkpoint.new(->(env) { env[:messages].assistant("a") }, path: path)
      env = { messages: Brute.log.tap { |l| l.user("go") }, metadata: {}, current_iteration: 1 }
      mw.call(env)
      mw.call(env)

      root = Brute::Middleware::Checkpoint.list(path).first
      Brute::Middleware::Checkpoint.new(->(env) { env[:messages].assistant("fork") }, path: path, resume: root[:id])
        .call({ messages: Brute.log, metadata: {}, current_iteration: 1 })

      Brute::Middleware::Checkpoint.list(path).last[:parent_id].should == root[:id]
    end
  end

  it "resume: :latest with no store yet starts fresh" do
    Dir.mktmpdir do |dir|
      env = { messages: Brute.log.tap { |l| l.user("go") }, metadata: {}, current_iteration: 1 }
      Brute::Middleware::Checkpoint.new(->(_e) {}, path: File.join(dir, "cp.jsonl"), resume: :latest).call(env)
      env[:messages].map(&:content).should == ["go"]
    end
  end

  it "raises on an unknown checkpoint id" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cp.jsonl")
      Brute::Middleware::Checkpoint.new(->(_e) {}, path: path).call(
        { messages: Brute.log, metadata: {}, current_iteration: 1 }
      )

      lambda do
        Brute::Middleware::Checkpoint.new(->(_e) {}, path: path, resume: "nope").call(
          { messages: Brute.log, metadata: {}, current_iteration: 1 }
        )
      end.should.raise(KeyError)
    end
  end

  it "does not persist system messages" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cp.jsonl")
      env = { messages: Brute.log, metadata: {}, current_iteration: 1 }
      env[:messages].system("rules")
      env[:messages].user("go")
      Brute::Middleware::Checkpoint.new(->(_e) {}, path: path).call(env)

      roles = Brute::Middleware::Checkpoint.list(path).last[:messages].map { |m| m[:role] }
      roles.should == ["user"]
    end
  end

  it "restores only once even though the loop re-enters" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cp.jsonl")
      Brute::Middleware::Checkpoint.new(->(env) { env[:messages].assistant("old") }, path: path)
        .call({ messages: Brute.log.tap { |l| l.user("hi") }, metadata: {}, current_iteration: 1 })

      calls = 0
      inner = ->(env) do
        calls += 1
        if calls < 2
          env[:messages] << Brute::Message.new(role: :tool, content: "r", tool_call_id: "tc1")
        else
          env[:messages].assistant("done")
        end
      end
      stack = Brute::Middleware::Loop::ToolResult.new(
        Brute::Middleware::Checkpoint.new(inner, path: path, resume: :latest)
      )
      env = { messages: Brute.log.tap { |l| l.user("again") }, metadata: {}, current_iteration: 1 }
      stack.call(env)

      env[:messages].count { |m| m.content == "old" }.should == 1
    end
  end
end
