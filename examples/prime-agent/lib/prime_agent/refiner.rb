# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "refinement"

module PrimeAgent
  # The refine orchestrator — shared state and flow for the refine
  # middleware (AutoRefine now, RefineOnExit in stage 4). Owns:
  #
  #  - the turn counter + cooldown for automatic refinement
  #    (prime-agent: autoRefine turnInterval 25, cooldown 20 min);
  #  - the refine-request file the kernel writes via `refine.run`
  #    (iruby has no control channel for prime-agent's comm bridge, so the
  #    bridge is `<local harness dir>/refine_request.json`, drained here);
  #  - the refinement history (`refinements.jsonl` per store dir — the
  #    analogue of prime-agent's session entries + global jsonl), which
  #    feeds the planning prompt and powers rollback.
  #
  # All LLM work is delegated to Refinement::Engine; failures are reported
  # on stderr and never break the agent turn.
  class Refiner
    DEFAULT_TURN_INTERVAL = 25
    DEFAULT_COOLDOWN_SECONDS = 20 * 60

    # The end-of-run distillation (stage 4): a one-shot session's equivalent
    # of prime-agent's compaction-checkpoint refine.
    FINAL_REFINE_INSTRUCTIONS = <<~TXT.strip.freeze
      The session is ending. Distill any durable, evidence-backed lessons from this trajectory into the continual harness: reusable tactics, durable facts or preferences, repeatable procedures worth a skill entry, or narrow behavior policies worth a prompt note. Prefer the local store; request global only for stable cross-session lessons. If nothing reusable emerged, return an empty edits array.
    TXT

    class Error < StandardError; end

    attr_reader :harness

    def initialize(harness:, llm:, turn_interval: nil, cooldown_seconds: DEFAULT_COOLDOWN_SECONDS,
                   refine_on_exit: nil)
      @harness = harness
      @engine = Refinement::Engine.new(llm: llm)
      @turn_interval = turn_interval || Integer(ENV.fetch("BRUTE_REFINE_TURNS", DEFAULT_TURN_INTERVAL))
      @cooldown_seconds = cooldown_seconds
      @refine_on_exit = refine_on_exit.nil? ? ENV["BRUTE_REFINE_FINAL"] != "0" : refine_on_exit
      @turns_since_review = 0
      @last_review_at = nil
      @mutex = Mutex.new
    end

    def local_dir
      @harness.local_store.dir
    end

    def global_dir
      @harness.global_store.dir
    end

    def request_path
      File.join(local_dir, "refine_request.json")
    end

    def local_history_path
      File.join(local_dir, "refinements.jsonl")
    end

    def global_history_path
      File.join(global_dir, "refinements.jsonl")
    end

    # Called by Middleware::AutoRefine after each LLM+tools pass. A pending
    # kernel `refine.run` request wins; otherwise the turn-interval review
    # gate decides. Never raises into the turn.
    def turn_boundary!(messages:)
      @mutex.synchronize do
        @turns_since_review += 1
        if (request = consume_refine_request)
          refine(instructions: request["instructions"],
                 scope: request["global"] ? "global" : "local",
                 rollback_id: request["rollback_id"],
                 messages: messages)
          reset_review_counter
        elsif @turns_since_review >= @turn_interval && cooldown_elapsed?
          review_and_refine(messages)
        end
      end
    rescue StandardError => error
      warn "[prime-agent] refine skipped: #{error.class}: #{error.message}"
      nil
    end

    # One full /refine pass against the target scope's store. Returns the
    # RefinementResult hash (also appended to history).
    def refine(instructions: nil, scope: "local", rollback_id: nil, messages: [])
      id = Refinement::Engine.new_refinement_id

      result =
        if rollback_id
          target = history.find { |record| record[:id] == rollback_id }
          raise Error, "Refinement #{rollback_id} not found" unless target

          proposal = Refinement.rollback_proposal(target)
          target_store = target[:scope] == "global" ? @harness.global_store : @harness.local_store
          Refinement.apply_proposal(target_store, proposal, id: id, rollback_of: target[:id])
        else
          store = scope == "global" ? @harness.global_store : @harness.local_store
          # Planning sees the merged state for local scope (global entries as
          # read-only context), the global state alone for global scope.
          planning_state = scope == "global" ? @harness.global_store.state : @harness.merged_state
          baseline = store.state
          proposal, id = @engine.plan(messages: messages, state: planning_state, history: history,
                                      instructions: instructions, scope: scope)
          strip_scope_prefixes!(proposal)
          # The store re-syncs from disk inside apply_proposal, so kernel
          # writes during planning are only rejected via the baseline check.
          Refinement.apply_proposal(store, proposal, id: id, baseline: baseline)
        end

      append_history(result)
      warn "[prime-agent] refine #{result[:id]}: #{result[:summary]} " \
           "(#{result[:applied_edits].count { |edit| edit[:applied] }} applied, " \
           "#{result[:applied_edits].count { |edit| !edit[:applied] }} skipped)"
      result
    end

    # Stage 4 — called by Middleware::RefineOnExit after the run finishes.
    # A pending kernel `refine.run` request wins; otherwise the final
    # distillation pass runs. One-shot runs never hit the turn interval, so
    # this is what makes the scheduled (systemd timer) setup learn across
    # runs. Never raises.
    def refine_on_exit(messages: [])
      return nil unless @refine_on_exit

      @mutex.synchronize do
        if (request = consume_refine_request)
          refine(instructions: request["instructions"],
                 scope: request["global"] ? "global" : "local",
                 rollback_id: request["rollback_id"],
                 messages: messages)
        else
          refine(instructions: FINAL_REFINE_INSTRUCTIONS, scope: "local", messages: messages)
        end
      end
    rescue StandardError => error
      warn "[prime-agent] final refine skipped: #{error.class}: #{error.message}"
      nil
    end

    # Refinement history across both jsonl files, local winning id
    # conflicts (prime-agent mergeRefinementHistory).
    def history
      records = {}
      [global_history_path, local_history_path].each do |path|
        next unless File.exist?(path)

        File.readlines(path).each do |line|
          record = parse_history_record(line)
          records[record[:id]] = record if record
        end
      end
      records.values
    end

    private

    def review_and_refine(messages)
      review = @engine.review(messages: messages, state: @harness.merged_state, history: history,
                              reason: "turn_interval", turns_since_last_review: @turns_since_review)
      reset_review_counter
      return nil unless review[:should_refine]

      instructions = +"Automatic refine review triggered by turn_interval. Only create/update/delete " \
                      "local harness entries if there is clear evidence in the recent trajectory. " \
                      "Reviewer rationale: #{review[:rationale]}"
      instructions << "\nReviewer instructions: #{review[:instructions]}" if review[:instructions]
      refine(instructions: instructions, scope: "local", messages: messages)
    end

    def consume_refine_request
      return nil unless File.exist?(request_path)

      request = JSON.parse(File.read(request_path))
      File.delete(request_path)
      request.is_a?(Hash) ? request : nil
    rescue JSON::ParserError
      File.delete(request_path)
      nil
    end

    def reset_review_counter
      @turns_since_review = 0
      @last_review_at = monotonic
    end

    def cooldown_elapsed?
      @last_review_at.nil? || (monotonic - @last_review_at) >= @cooldown_seconds
    end

    # Edits carry bare ids; the `local:`/`global:` display prefixes are
    # stripped before applying (prime-agent _applyRefine).
    def strip_scope_prefixes!(proposal)
      proposal[:edits].each do |edit|
        next unless edit[:id]

        edit[:id] = HarnessStore.strip_scope_prefix(edit[:id]).first
      end
    end

    def append_history(result)
      append_jsonl(local_history_path, result)
      append_jsonl(global_history_path, result) if result[:scope] == "global"
    end

    def append_jsonl(path, record)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |file| file.puts(JSON.generate(record)) }
      File.chmod(0o600, path)
    end

    def parse_history_record(line)
      value = JSON.parse(line)
      return nil unless value.is_a?(Hash) && value["id"].is_a?(String) && value["applied_edits"].is_a?(Array)

      {
        id: value["id"],
        summary: value["summary"].to_s,
        rationale: value["rationale"].to_s,
        expected_outcome: value["expected_outcome"].to_s,
        applied_edits: value["applied_edits"].map do |edit|
          edit.each_with_object({}) { |(key, field), record| record[key.to_sym] = field }
        end,
        scope: value["scope"],
        rollback_of: value["rollback_of"],
      }
    rescue JSON::ParserError
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

__END__

require "brute/messages"
require "tmpdir"

describe "prime_agent/refiner" do
  def build(turn_interval: 25, llm: nil)
    local_dir = Dir.mktmpdir
    global_dir = Dir.mktmpdir
    harness = PrimeAgent::Harness.new(
      local_store: PrimeAgent::HarnessStore.new(local_dir, scope: "local"),
      global_store: PrimeAgent::HarnessStore.new(global_dir, scope: "global"),
    )
    llm ||= ->(system:, user:, max_tokens:) { %q({"summary": "s", "edits": []}) }
    refiner = PrimeAgent::Refiner.new(harness: harness, llm: llm, turn_interval: turn_interval,
                                      cooldown_seconds: 0)
    [refiner, harness, local_dir, global_dir]
  end

  CREATE_PROPOSAL = %q({
    "summary": "save the deploy lesson",
    "rationale": "the trajectory showed it",
    "expectedOutcome": "future runs know",
    "edits": [
      {"action": "create", "kind": "memory", "title": "Deploy command", "content": "bin/deploy --prod"}
    ]
  })

  it "runs a full refine pass: applies edits, records event, appends history" do
    refiner, harness, _local_dir, _global_dir = build(llm: ->(**_) { CREATE_PROPOSAL })
    result = refiner.refine(messages: [Brute::Message.new(role: :user, content: "task")])

    result[:summary].should == "save the deploy lesson"
    result[:applied_edits].first[:applied].should.be.true
    harness.local_store.get("memory", "deploy_command")["content"].should == "bin/deploy --prod"
    harness.local_store.refinements.first["trigger"].should == "save the deploy lesson"
    refiner.history.map { |record| record[:id] }.should == [result[:id]]
  end

  it "rolls back a prior refinement by id" do
    refiner, harness, = build(llm: ->(**_) { CREATE_PROPOSAL })
    result = refiner.refine
    harness.local_store.get("memory", "deploy_command").should.not.be.nil

    rollback = refiner.refine(rollback_id: result[:id])
    rollback[:rollback_of].should == result[:id]
    harness.local_store.get("memory", "deploy_command").should.be.nil
  end

  it "refine with unknown rollback id raises" do
    refiner, = build
    lambda { refiner.refine(rollback_id: "refine_nope") }.should.raise(PrimeAgent::Refiner::Error)
  end

  it "drains the kernel refine-request file at a turn boundary" do
    refiner, harness, _local_dir, _global_dir = build(llm: ->(**_) { CREATE_PROPOSAL })
    FileUtils.mkdir_p(refiner.local_dir)
    File.write(refiner.request_path, JSON.generate({ "instructions" => nil, "global" => false,
                                                     "rollback_id" => nil }))

    refiner.turn_boundary!(messages: [])

    File.exist?(refiner.request_path).should.be.false
    harness.local_store.get("memory", "deploy_command").should.not.be.nil
  end

  it "auto-refines only after the turn interval, via the review gate" do
    calls = []
    llm = lambda do |system:, user:, max_tokens:|
      calls << system
      system.include?("review gate") ? %q({"shouldRefine": false, "rationale": "nothing yet"})
                                     : CREATE_PROPOSAL
    end
    refiner, harness, = build(turn_interval: 2, llm: llm)

    refiner.turn_boundary!(messages: [])
    harness.local_store.list.should == [] # turn 1: no review yet

    refiner.turn_boundary!(messages: [])
    harness.local_store.list.should == [] # turn 2: review said no
    calls.length.should == 1             # gate was consulted once

    refiner.turn_boundary!(messages: [])
    harness.local_store.list.should == [] # counter reset; next review at turn 4
  end

  it "never raises into the turn — failures land on stderr" do
    failing = ->(**_) { raise "llm is down" }
    refiner, = build(llm: failing)
    FileUtils.mkdir_p(refiner.local_dir)
    File.write(refiner.request_path, JSON.generate({ "instructions" => "go" }))

    lambda { refiner.turn_boundary!(messages: []) }.should.not.raise
    File.exist?(refiner.request_path).should.be.false
  end

  it "refine_on_exit runs the final distillation pass" do
    captured = nil
    llm = lambda do |system:, user:, max_tokens:|
      captured = user
      CREATE_PROPOSAL
    end
    refiner, harness, = build(llm: llm)
    refiner.refine_on_exit(messages: [Brute::Message.new(role: :user, content: "the task")])

    captured.should.include PrimeAgent::Refiner::FINAL_REFINE_INSTRUCTIONS
    captured.should.include "[User]: the task"
    harness.local_store.get("memory", "deploy_command").should.not.be.nil
  end

  it "refine_on_exit prefers a pending kernel refine request over the generic distill" do
    refiner, harness, = build(llm: ->(**_) { CREATE_PROPOSAL })
    FileUtils.mkdir_p(refiner.local_dir)
    File.write(refiner.request_path, JSON.generate({ "instructions" => "focused note", "global" => false,
                                                     "rollback_id" => nil }))
    refiner.refine_on_exit(messages: [])

    File.exist?(refiner.request_path).should.be.false
    harness.local_store.get("memory", "deploy_command").should.not.be.nil
  end

  it "refine_on_exit is disabled with refine_on_exit: false (BRUTE_REFINE_FINAL=0)" do
    Dir.mktmpdir do |local_dir|
      Dir.mktmpdir do |global_dir|
        harness = PrimeAgent::Harness.new(
          local_store: PrimeAgent::HarnessStore.new(local_dir, scope: "local"),
          global_store: PrimeAgent::HarnessStore.new(global_dir, scope: "global"),
        )
        refiner = PrimeAgent::Refiner.new(harness: harness, llm: ->(**_) { CREATE_PROPOSAL },
                                          refine_on_exit: false)
        refiner.refine_on_exit(messages: [])
        harness.local_store.list.should == []
      end
    end
  end

  it "refine_on_exit never raises" do
    refiner, = build(llm: ->(**_) { raise "llm is down" })
    lambda { refiner.refine_on_exit(messages: []) }.should.not.raise
  end
end
