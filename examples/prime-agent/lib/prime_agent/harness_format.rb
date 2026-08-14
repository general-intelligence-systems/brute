# frozen_string_literal: true

require "json"

require_relative "harness_store"

module PrimeAgent
  # Renders harness state for the system prompt — a Ruby port of
  # formatHarnessStateForPrompt (packages/coding-agent/src/core/refinement/
  # refinement.ts:429-520), adapted for the IRuby port:
  #
  #  - the refine-skill line references `refine.run()` (no `await`; the
  #    in-kernel refine proxy lands in stage 3);
  #  - the call contract is the Ruby one (HarnessStore::CALL_CONTRACT) —
  #    no Python skills, no `rlm(...)` subagent spawn form;
  #  - the subagent header has no rlm invocation hint.
  #
  # Input is a merged state hash as produced by Harness#merged_state.
  module HarnessFormat
    DEFAULT_ENTRY_LIMIT = 6
    DEFAULT_REFINEMENT_LIMIT = 5
    DEFAULT_CONTENT_LIMIT = 180

    WHEN_TO_REFINE = <<~TXT.tr("\n", " ").squeeze(" ").freeze
      When to call `refine.run()`: after a repeated failure, a reusable
      tactic emerges, a repeated delegation role should become a subagent
      spec, a repeated procedure should become a skill, a durable
      fact/preference should become a memory, a narrow behavioral policy
      should become a prompt addendum, a user corrects behavior that should
      persist locally or globally, validation shows a continual harness entry
      is wrong, or a skill/subagent/memory/prompt note should be created,
      updated, deleted, or rolled back. Keep `refine.run()` continual harness
      edits small and evidence-backed.
    TXT

    HEADER = <<~TXT.strip.freeze
      # Continual Harness State

      Local continual harness entries belong to this Prime Agent session. Global continual harness entries persist across Prime Agent sessions.
      The continual harness entries below are compact summaries, not full descriptions. Use them as routing/context hints; inspect or refine the underlying continual harness entry only when detail matters.
      Default to local continual harness refinement for current task progress, temporary blockers, and session coordination. Use global continual harness refinement only for stable cross-session lessons, durable user preferences, reusable skills/subagents, or explicitly project-qualified facts.
      Use these continual harness prompt notes, memories, skills, and subagent specs when they are relevant. The base system prompt is immutable; prompt entries below are supplemental notes only.
    TXT

    module_function

    def format_harness_state_for_prompt(state,
                                        max_entries_per_kind: DEFAULT_ENTRY_LIMIT,
                                        max_refinements: DEFAULT_REFINEMENT_LIMIT,
                                        max_content_length: DEFAULT_CONTENT_LIMIT)
      lines = [
        HEADER,
        WHEN_TO_REFINE,
        "Call contract: #{HarnessStore::CALL_CONTRACT}",
        "",
      ]

      total_entries = 0
      HarnessStore::KINDS.each do |kind|
        entries = state["entries"][kind].values.sort_by do |entry|
          [entry["path"], entry["title"], entry["id"]].join("\0")
        end
        total_entries += entries.length
        lines << "#{kind}: #{entries.length}"
        entries.first(max_entries_per_kind).each do |entry|
          lines << "- #{HarnessStore.summarize_entry(entry, max_content_length)}"
        end
        overflow = entries.length - [entries.length, max_entries_per_kind].min
        lines << "- +#{overflow} more #{kind} entries" if overflow.positive?
        lines << ""
      end

      lines << "No saved harness entries yet." << "" if total_entries.zero?

      refinements = state["refinements"]
      lines << "recent refinements: #{refinements.length}"
      refinements.last(max_refinements).each do |event|
        changes = event["changes"].empty? ? "no applied edits" : event["changes"].join(", ")
        outcome = event["outcome"].to_s.empty? ? "" : "; outcome: #{compact(event["outcome"], max_content_length)}"
        lines << "- [#{event["id"]}] #{compact(event["trigger"], max_content_length)}: #{changes}#{outcome}"
      end
      refinement_overflow = refinements.length - [refinements.length, max_refinements].min
      lines << "- +#{refinement_overflow} older refinement events" if refinement_overflow.positive?

      lines.join("\n").strip
    end

    def compact(text, max_length)
      HarnessStore.compact_text(text, max_length)
    end
  end
end

__END__

describe "prime_agent/harness_format" do
  def empty_state
    { "schema" => 1, "entries" => PrimeAgent::HarnessStore.empty_entries, "refinements" => [] }
  end

  def entry(kind, id, title, content, scope: "local", path: "general", version: 1, extra: {})
    { "id" => id, "kind" => kind, "title" => title, "content" => content,
      "path" => path, "scope" => scope, "version" => version }.merge(extra)
  end

  it "renders the header and empty-state line for an empty harness" do
    out = PrimeAgent::HarnessFormat.format_harness_state_for_prompt(empty_state)
    out.should.include "# Continual Harness State"
    out.should.include "No saved harness entries yet."
    out.should.include "prompt: 0"
    out.should.include "memory: 0"
    out.should.include "skill: 0"
    out.should.include "subagent: 0"
    out.should.include "recent refinements: 0"
    out.should.include "refine.run()"
    out.should.include "Call contract:"
  end

  it "renders entries with scope prefixes, sorted by path/title/id" do
    state = empty_state
    state["entries"]["memory"]["b"] = entry("memory", "b", "Beta", "second")
    state["entries"]["memory"]["a"] = entry("memory", "a", "Alpha", "first", scope: "global")
    out = PrimeAgent::HarnessFormat.format_harness_state_for_prompt(state)
    out.should.include "memory: 2"
    out.should.include "- [global:a] Alpha (general, v1): first"
    out.should.include "- [local:b] Beta (general, v1): second"
    out.index("Alpha").should.be < out.index("Beta")
    out.should.not.include "No saved harness entries yet."
  end

  it "caps entries per kind with an overflow line" do
    state = empty_state
    9.times { |i| state["entries"]["memory"]["m#{i}"] = entry("memory", "m#{i}", "T#{i}", "c") }
    out = PrimeAgent::HarnessFormat.format_harness_state_for_prompt(state)
    out.should.include "memory: 9"
    out.should.include "- +3 more memory entries"
  end

  it "shows ref/args for skill entries only" do
    state = empty_state
    state["entries"]["skill"]["fix"] = entry(
      "skill", "fix", "Fixer", "fixes things",
      extra: { "reference" => { "type" => "ruby", "import" => "fixer", "callable" => "Fixer.call" },
               "arguments" => { "x" => { "type" => "string" } } },
    )
    state["entries"]["memory"]["m"] = entry("memory", "m", "Mem", "plain")
    out = PrimeAgent::HarnessFormat.format_harness_state_for_prompt(state)
    out.should.include %q{ref={"type":"ruby","import":"fixer","callable":"Fixer.call"}}
    out.should.include "args="
    out.should.not.include %q{[local:m] Mem (general, v1) ref=}
  end

  it "renders recent refinements with outcomes and overflow" do
    state = empty_state
    7.times do |i|
      state["refinements"] << { "id" => "refine_%04d" % (i + 1), "trigger" => "trig#{i}",
                                "changes" => ["create memory:m#{i}"], "evidence" => "",
                                "outcome" => i == 6 ? "learned" : "", "created_at" => "now" }
    end
    out = PrimeAgent::HarnessFormat.format_harness_state_for_prompt(state)
    out.should.include "recent refinements: 7"
    out.should.include "- [refine_0007] trig6: create memory:m6; outcome: learned"
    out.should.include "- +2 older refinement events"
    out.should.not.include "refine_0001]"
  end

  it "compacts long content to the limit" do
    state = empty_state
    state["entries"]["memory"]["big"] = entry("memory", "big", "Big", "x" * 500)
    out = PrimeAgent::HarnessFormat.format_harness_state_for_prompt(state)
    out.should.include "..."
    out.should.not.include "x" * 200
  end
end
