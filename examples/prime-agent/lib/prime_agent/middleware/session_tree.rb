# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

require_relative "../compaction"

module PrimeAgent
  module Middleware
    # SessionTree — per-turn middleware (outer services layer). The port of
    # prime-agent's session branching (core/agent-session.ts navigateTree +
    # core/compaction/branch-summarization.ts), adapted to this port's
    # process model: "navigation" is FORKING a new run from a prior run's
    # transcript (BRUTE_FORK=<log>[#<entry-id>]); the abandoned tail of the
    # source log is summarized and injected at the join point, exactly
    # upstream's branch-summary-on-navigate. A fork at the leaf is a clone
    # (no summary).
    #
    # Every message is journaled to a per-run JSONL log with id/parent_id
    # linkage (entries e0001, e0002, ...), so later runs can fork from it.
    # When compaction rewrites the live log, the injected summary message is
    # journaled like any other entry.
    class SessionTree
      def initialize(app, llm:, log_path:, fork_from: nil, context_window: nil, reserve_tokens: 16_384)
        @app = app
        @llm = llm
        @log_path = log_path
        @fork_source, @fork_entry_id = fork_from ? fork_from.split("#", 2) : [nil, nil]
        @context_window = context_window
        @reserve_tokens = reserve_tokens
        @forked = @fork_source.nil? || @fork_source.empty?
        @cursor = 0
        @counter = 0
      end

      def call(env)
        apply_fork(env) unless @forked
        @app.call(env)
        journal(env)
        env
      end

      # --------------------------------------------------------------
      # Forking
      # --------------------------------------------------------------

      def apply_fork(env)
        @forked = true
        entries = self.class.read_entries(@fork_source)
        raise "BRUTE_FORK: no entries in #{@fork_source}" if entries.empty?

        fork_index =
          if @fork_entry_id
            found = entries.index { |entry| entry["id"] == @fork_entry_id }
            raise "BRUTE_FORK: no entry #{@fork_entry_id} in #{@fork_source}" unless found

            found
          else
            entries.length - 1 # the leaf — a clone
          end

        seeded = entries[0..fork_index]
        tail = entries[(fork_index + 1)..] || []

        system = env[:messages].select { |message| message.role == :system }
        task = env[:messages].reject { |message| message.role == :system }
        # The source's own system entries are skipped — the new run renders
        # its current prompt; history starts from the first user message.
        rebuilt = system + seeded.reject { |entry| entry["role"] == "system" }
                            .map { |entry| self.class.entry_to_message(entry) }

        unless tail.empty?
          summary = PrimeAgent::Compaction.generate_branch_summary(
            tail.map { |entry| self.class.entry_to_message(entry) },
            llm: @llm, context_window: @context_window, reserve_tokens: @reserve_tokens,
          )[:summary]
          rebuilt << Brute::Message.new(
            role: :user,
            content: "#{PrimeAgent::Compaction::BRANCH_SUMMARY_PREFIX}#{summary}#{PrimeAgent::Compaction::BRANCH_SUMMARY_SUFFIX}",
          )
        end

        env[:messages].replace(rebuilt + task)
        journal_marker("fork", "source" => @fork_source, "entry" => seeded.last["id"])
        journal(env)
      end

      # --------------------------------------------------------------
      # The JSONL entry log
      # --------------------------------------------------------------

      def journal(env)
        messages = env[:messages]
        if @cursor > messages.length
          # compaction rewrote the log: the summary message (index 1) is new.
          summary = messages[1]
          append_entry(summary) if summary && summary.content.to_s.include?(PrimeAgent::Compaction::SUMMARY_PREFIX)
          @cursor = messages.length
          return
        end
        (messages[@cursor..] || []).each { |message| append_entry(message) }
        @cursor = messages.length
      end

      def journal_marker(type, fields)
        FileUtils.mkdir_p(File.dirname(@log_path))
        File.open(@log_path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          file.write("#{JSON.generate({ "type" => type, "at" => Time.now.utc.iso8601 }.merge(fields))}\n")
        end
      end

      def append_entry(message)
        @counter += 1
        entry = {
          "id" => format("e%04d", @counter),
          "parent_id" => @counter > 1 ? format("e%04d", @counter - 1) : nil,
          "role" => message.role.to_s,
          "content" => message.content,
          "at" => Time.now.utc.iso8601,
        }
        calls = Array(message.tool_calls).map { |call| { "id" => call.id, "name" => call.name, "arguments" => call.arguments } }
        entry["tool_calls"] = calls unless calls.empty?
        FileUtils.mkdir_p(File.dirname(@log_path))
        File.open(@log_path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          file.write("#{JSON.generate(entry)}\n")
        end
      end

      def self.read_entries(path)
        return [] unless File.exist?(path)

        File.foreach(path).filter_map do |line|
          entry =
            begin
              JSON.parse(line)
            rescue JSON::ParserError
              nil
            end
          entry unless entry.nil? || entry["role"].nil? # markers have no role
        end
      end

      def self.entry_to_message(entry)
        Brute::Message.new(
          role: entry["role"],
          content: entry["content"],
          tool_calls: entry["tool_calls"],
        )
      end
    end
  end
end

__END__

describe "prime_agent/middleware/session_tree" do
  require "brute/messages"
  require "tmpdir"

  # Not LLM: that is llm.rb's own top-level module.
  FAKE_LLM = ->(system:, user:, max_tokens:) { "branch summary text" }

  def build(dir, **opts)
    app = lambda do |env|
      env[:messages].assistant("answer #{env[:messages].length}")
      env
    end
    PrimeAgent::Middleware::SessionTree.new(
      app, llm: FAKE_LLM, log_path: File.join(dir, "logs", "run.jsonl"), **opts,
    )
  end

  def env_with_task(task = "the task")
    log = Brute.log
    log.system("sys")
    log.user(task)
    { messages: log }
  end

  it "journals messages with id/parent linkage" do
    Dir.mktmpdir do |dir|
      middleware = build(dir)
      middleware.call(env_with_task)
      entries = PrimeAgent::Middleware::SessionTree.read_entries(File.join(dir, "logs", "run.jsonl"))
      entries.map { |e| e["role"] }.should == %w[system user assistant]
      entries[1]["parent_id"].should == entries[0]["id"]
      entries.map { |e| e["id"] }.should == %w[e0001 e0002 e0003]
    end
  end

  it "forks at an entry, seeding history and summarizing the abandoned tail" do
    Dir.mktmpdir do |dir|
      source = build(dir)
      env = env_with_task("original task")
      source.call(env)
      env[:messages].user("second question")
      source.call(env)
      source_path = File.join(dir, "logs", "run.jsonl")

      forked = build(dir, fork_from: "#{source_path}#e0002")
      fork_env = env_with_task("new direction")
      forked.call(fork_env)

      contents = fork_env[:messages].map { |m| m.content.to_s }
      contents[0].should == "sys"
      contents.should.include "original task"
      summary = fork_env[:messages].find { |m| m.content.to_s.include?("came back from") }
      summary.should.not.be.nil
      summary.role.should == :user
      summary.content.should.include "branch summary text"
      summary.content.should.include PrimeAgent::Compaction::BRANCH_SUMMARY_PREAMBLE.strip.split("\n").first
      fork_env[:messages][-2].content.should == "new direction" # the appends its answer after it
    end
  end

  it "clones at the leaf without a summary" do
    Dir.mktmpdir do |dir|
      source = build(dir)
      source.call(env_with_task("task one"))
      source_path = File.join(dir, "logs", "run.jsonl")

      forked = build(dir, fork_from: source_path)
      fork_env = env_with_task("same direction")
      forked.call(fork_env)
      fork_env[:messages].none? { |m| m.content.to_s.include?("came back from") }.should.be.true
      fork_env[:messages].map { |m| m.content.to_s }.should.include "task one"
    end
  end

  it "raises a clear error for an unknown fork entry" do
    Dir.mktmpdir do |dir|
      build(dir).call(env_with_task)
      forked = build(dir, fork_from: "#{File.join(dir, "logs", "run.jsonl")}#e9999")
      lambda { forked.call(env_with_task) }.should.raise(RuntimeError)
    end
  end
end
