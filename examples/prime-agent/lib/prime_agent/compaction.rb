# frozen_string_literal: true

require "json"

require_relative "prompts"

module PrimeAgent
  # Context compaction core — the port of prime-agent's
  # packages/coding-agent/src/core/compaction/{compaction,utils}.ts: pure
  # functions over the message log; the middleware (middleware/compaction.rb)
  # handles I/O. Algorithm, prompts, and defaults are ported verbatim;
  # message-shape adaptations are noted per method (brute messages are
  # role/content/tool_calls — no thinking blocks, images, or bashExecution).
  #
  # The three triggers live in the middleware; this module answers "should we
  # compact" (threshold), "what would be summarized" (prepare_compaction),
  # and "do it" (compact).
  #
  # Pure stdlib — loadable without brute or any gem.
  module Compaction
    COMPACT_SKILL_NAME = "compact"

    # Mirrors DEFAULT_COMPACTION_SETTINGS (compaction.ts:128-132).
    Settings = Data.define(:enabled, :reserve_tokens, :keep_recent_tokens)
    DEFAULT_SETTINGS = Settings.new(enabled: true, reserve_tokens: 16_384, keep_recent_tokens: 20_000)

    # The injected summary message flattens to a user message wrapped in
    # these (messages.ts:13-19 COMPACTION_SUMMARY_PREFIX/SUFFIX).
    SUMMARY_PREFIX = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
    SUMMARY_SUFFIX = "\n</summary>"

    # Appended to every summarization prompt (compaction.ts:498-499), adapted
    # to this port's kernel.
    KERNEL_PERSIST_SUMMARY_NOTE =
      "Note: the IRuby kernel keeps running after this summary — every Ruby variable, method, and helper you defined stays available. The cells that defined them won't appear above, so record in the summary any names worth remembering so you reuse them instead of redefining them."

    # Maximum characters for a tool result in serialized summaries (utils.ts:83).
    TOOL_RESULT_MAX_CHARS = 2000

    # Branch summaries (branch-summarization.ts:248-280 + messages.ts:21-26):
    # the preamble rides inside the summary; the PREFIX/SUFFIX wrap the
    # injected user message.
    BRANCH_SUMMARY_PREAMBLE = "The user explored a different conversation branch before returning here.\nSummary of that exploration:\n\n"
    BRANCH_SUMMARY_PREFIX = "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n"
    BRANCH_SUMMARY_SUFFIX = "\n</summary>"

    # ------------------------------------------------------------------
    # Token calculation (compaction.ts:138-233)
    # ------------------------------------------------------------------

    # calculateContextTokens — native total when present, else components.
    def self.calculate_context_tokens(usage)
      total = usage[:total] || usage[:total_tokens]
      return total if total

      usage.fetch(:input, 0) + usage.fetch(:output, 0) +
        usage.fetch(:cache_read, 0) + usage.fetch(:cache_write, 0)
    end

    # estimateTokens — chars/4 heuristic (conservative overestimate).
    # brute message roles map onto upstream: user -> user, assistant ->
    # assistant (text + toolCall name/arguments), tool -> toolResult,
    # system -> not an LLM conversation message (0, as upstream's fallthrough).
    def self.estimate_tokens(message)
      chars =
        case message.role
        when :user, :tool
          message.content.to_s.length
        when :assistant
          content_chars = message.content.to_s.length
          call_chars = Array(message.tool_calls).sum do |call|
            call.name.to_s.length + JSON.generate(call.arguments || {}).length
          end
          content_chars + call_chars
        else
          0
        end
      (chars / 4.0).ceil
    end

    ContextUsageEstimate = Data.define(:tokens, :usage_tokens, :trailing_tokens, :last_usage_index)

    # estimateContextTokens — real usage from the last assistant message when
    # a message carries it (duck-typed `usage`; brute's transport does not
    # attach usage to messages, so in practice the estimate path runs — the
    # same degradation upstream has right after a compaction, where usage is
    # absent). Trailing messages after the last usage are estimated.
    def self.estimate_context_tokens(messages)
      usage_info = nil
      (messages.length - 1).downto(0) do |i|
        message = messages[i]
        next unless message.respond_to?(:usage) && message.usage

        usage_info = { usage: message.usage, index: i }
        break
      end

      unless usage_info
        estimated = messages.sum { |message| estimate_tokens(message) }
        return ContextUsageEstimate.new(
          tokens: estimated, usage_tokens: 0, trailing_tokens: estimated, last_usage_index: nil,
        )
      end

      usage_tokens = calculate_context_tokens(usage_info[:usage])
      trailing = 0
      ((usage_info[:index] + 1)...messages.length).each do |i|
        trailing += estimate_tokens(messages[i])
      end
      ContextUsageEstimate.new(
        tokens: usage_tokens + trailing,
        usage_tokens: usage_tokens,
        trailing_tokens: trailing,
        last_usage_index: usage_info[:index],
      )
    end

    # shouldCompact (compaction.ts:229-233).
    def self.should_compact?(context_tokens, context_window, settings)
      return false unless settings.enabled
      return false if context_window <= 0

      context_tokens > context_window - settings.reserve_tokens
    end

    # ------------------------------------------------------------------
    # Cut point detection (compaction.ts:303-459)
    # ------------------------------------------------------------------

    # Valid cut points: user and assistant messages. Never tool results
    # (they must follow their tool call); never system (it is re-rendered
    # outside the conversation, and upstream's valid roles exclude it).
    def self.valid_cut_point?(message)
      message.role == :user || message.role == :assistant
    end

    # The user message that starts the turn containing index, or -1.
    def self.find_turn_start_index(messages, index, start_index)
      index.downto(start_index) do |i|
        return i if messages[i].role == :user
      end
      -1
    end

    CutPoint = Data.define(:first_kept_index, :turn_start_index, :split_turn?)

    # findCutPoint — walk backwards from the newest message accumulating
    # chars/4 sizes; stop at >= keep_recent_tokens and cut at the closest
    # valid cut point at or after that index. (Upstream also scans back over
    # non-message entries to keep them with the cut — brute's log holds only
    # messages, so there is nothing to scan.)
    def self.find_cut_point(messages, start_index, end_index, keep_recent_tokens)
      cut_points = (start_index...end_index).select { |i| valid_cut_point?(messages[i]) }
      return CutPoint.new(first_kept_index: start_index, turn_start_index: -1, split_turn?: false) if cut_points.empty?

      accumulated = 0
      cut_index = cut_points.first
      (end_index - 1).downto(start_index) do |i|
        accumulated += estimate_tokens(messages[i])
        next unless accumulated >= keep_recent_tokens

        cut_index = cut_points.find { |point| point >= i } || cut_index
        break
      end

      is_user = messages[cut_index].role == :user
      turn_start = is_user ? -1 : find_turn_start_index(messages, cut_index, start_index)
      CutPoint.new(
        first_kept_index: cut_index,
        turn_start_index: turn_start,
        split_turn?: !is_user && turn_start != -1,
      )
    end

    # ------------------------------------------------------------------
    # File operation tracking (utils.ts:9-76)
    # ------------------------------------------------------------------

    # Upstream extracts `edit` tool CALLS (args.path) from assistant
    # messages; this port's edits are kernel-side Edit.run calls whose diff
    # displays land on the iruby TOOL RESULT as "diff <path>:<line>" blocks
    # (iruby_tool.rb render_diff) — so the tool messages are scanned for
    # those headers. Same effective coverage: upstream tracks edits only.
    DIFF_HEADER = /^diff (.+):(\d+)$/

    def self.extract_modified_files(messages)
      modified = []
      messages.each do |message|
        next unless message.role == :tool

        message.content.to_s.scan(DIFF_HEADER) { |(path, _line)| modified << path unless modified.include?(path) }
      end
      modified
    end

    # computeFileLists — upstream's read set is never populated by any tool,
    # so read_files is always empty and modified_files is the sorted edit set.
    def self.compute_file_lists(modified_files)
      { read_files: [], modified_files: modified_files.sort }
    end

    # formatFileOperations — XML appended to the summary.
    def self.format_file_operations(read_files, modified_files)
      sections = []
      sections << "<read-files>\n#{read_files.join("\n")}\n</read-files>" unless read_files.empty?
      sections << "<modified-files>\n#{modified_files.join("\n")}\n</modified-files>" unless modified_files.empty?
      return "" if sections.empty?

      "\n\n#{sections.join("\n\n")}"
    end

    # ------------------------------------------------------------------
    # Message serialization (utils.ts:82-156)
    # ------------------------------------------------------------------

    def self.truncate_for_summary(text, max_chars = TOOL_RESULT_MAX_CHARS)
      return text if text.length <= max_chars

      "#{text[0...max_chars]}\n\n[... #{text.length - max_chars} more characters truncated]"
    end

    # serializeConversation — text form so the summarizer doesn't continue
    # the conversation. System messages are not conversation messages
    # (upstream serializes the convertToLlm output, which excludes them).
    def self.serialize_conversation(messages)
      parts = []
      messages.each do |message|
        case message.role
        when :user
          content = message.content.to_s
          parts << "[User]: #{content}" unless content.empty?
        when :assistant
          text = message.content.to_s
          parts << "[Assistant]: #{text}" unless text.empty?
          calls = Array(message.tool_calls).map do |call|
            args = (call.arguments || {}).map { |key, value| "#{key}=#{JSON.generate(value)}" }.join(", ")
            "#{call.name}(#{args})"
          end
          parts << "[Assistant tool calls]: #{calls.join("; ")}" unless calls.empty?
        when :tool
          content = message.content.to_s
          parts << "[Tool result]: #{truncate_for_summary(content)}" unless content.empty?
        end
      end
      parts.join("\n\n")
    end

    # ------------------------------------------------------------------
    # Summarization (compaction.ts:461-612, 723-867)
    # ------------------------------------------------------------------

    # buildSummarizationPrompt — initial or update template, optional user
    # instructions, and the kernel persistence note.
    def self.build_summarization_prompt(custom_instructions: nil, previous_summary: nil)
      base = previous_summary ? Prompts.load("compact_update") : Prompts.load("compact_summarize")
      if custom_instructions
        base += "\n\n<user-instructions>\nThe user provided these instructions for this summary. Follow them with high priority while keeping the section format above: emphasize what they ask to focus on, and preserve verbatim anything they ask to remember.\n#{custom_instructions}\n</user-instructions>"
      end
      "#{base}\n\n#{KERNEL_PERSIST_SUMMARY_NOTE}"
    end

    # generateSummary — one role:user call, <conversation>-wrapped; the
    # update variant merges <previous-summary>. maxTokens = 0.8 * reserve.
    # llm: (system:, user:, max_tokens:) -> String (raises on failure).
    def self.generate_summary(messages, llm:, reserve_tokens:, custom_instructions: nil, previous_summary: nil)
      max_tokens = (0.8 * reserve_tokens).floor
      prompt = +"<conversation>\n#{serialize_conversation(messages)}\n</conversation>\n\n"
      prompt += "<previous-summary>\n#{previous_summary}\n</previous-summary>\n\n" if previous_summary
      prompt += build_summarization_prompt(custom_instructions: custom_instructions, previous_summary: previous_summary)
      llm.call(system: Prompts.load("compact_summarize_system"), user: prompt, max_tokens: max_tokens)
    end

    # generateTurnPrefixSummary — smaller budget: maxTokens = 0.5 * reserve.
    def self.generate_turn_prefix_summary(messages, llm:, reserve_tokens:)
      max_tokens = (0.5 * reserve_tokens).floor
      prompt = "<conversation>\n#{serialize_conversation(messages)}\n</conversation>\n\n#{Prompts.load("compact_turn_prefix")}"
      llm.call(system: Prompts.load("compact_summarize_system"), user: prompt, max_tokens: max_tokens)
    end

    # ------------------------------------------------------------------
    # Preparation + main compaction (compaction.ts:618-825)
    # ------------------------------------------------------------------

    Preparation = Data.define(
      :first_kept_index, :turn_start_index, :messages_to_summarize, :turn_prefix_messages,
      :split_turn?, :tokens_before, :previous_summary, :modified_files, :settings
    )

    # prepareCompaction.
    #
    # `boundary` marks the previous compaction in the log: nil, or a Hash
    # { summary:, summary_message:, first_kept_message:, modified_files: }
    # where the messages are found by IDENTITY (the middleware injected them).
    # Returns nil when there is nothing to do: the log already ends at the
    # previous compaction, or everything fits and there is no previous
    # summary to carry forward.
    def self.prepare_compaction(messages, settings:, boundary: nil)
      return nil if boundary && messages.last.equal?(boundary[:summary_message])

      previous_summary = nil
      modified_files = []
      boundary_start = 0

      if boundary
        prev_index = messages.index { |message| message.equal?(boundary[:summary_message]) }
        if prev_index
          previous_summary = boundary[:summary]
          modified_files |= Array(boundary[:modified_files])
          first_kept_index = messages.index { |message| message.equal?(boundary[:first_kept_message]) }
          boundary_start = first_kept_index || prev_index + 1
        end
      end

      conversation = messages.reject { |message| message.role == :system }
      tokens_before = estimate_context_tokens(conversation).tokens

      cut = find_cut_point(messages, boundary_start, messages.length, settings.keep_recent_tokens)
      history_end = cut.split_turn? ? cut.turn_start_index : cut.first_kept_index

      to_summarize = messages[boundary_start...history_end].reject { |message| message.role == :system }
      turn_prefix =
        if cut.split_turn?
          messages[cut.turn_start_index...cut.first_kept_index].reject { |message| message.role == :system }
        else
          []
        end

      return nil if to_summarize.empty? && turn_prefix.empty? && previous_summary.nil?

      modified_files |= extract_modified_files(to_summarize)
      modified_files |= extract_modified_files(turn_prefix)

      Preparation.new(
        first_kept_index: cut.first_kept_index,
        turn_start_index: cut.turn_start_index,
        messages_to_summarize: to_summarize,
        turn_prefix_messages: turn_prefix,
        split_turn?: cut.split_turn?,
        tokens_before: tokens_before,
        previous_summary: previous_summary,
        modified_files: modified_files,
        settings: settings,
      )
    end

    # compact — generate the summary (history + turn prefix when splitting),
    # append file tracking, and return what the middleware needs to rebuild
    # the log.
    def self.compact(preparation, llm:, custom_instructions: nil)
      summary =
        if preparation.split_turn? && preparation.turn_prefix_messages.any?
          history =
            if preparation.messages_to_summarize.any?
              generate_summary(
                preparation.messages_to_summarize, llm: llm,
                reserve_tokens: preparation.settings.reserve_tokens,
                custom_instructions: custom_instructions,
                previous_summary: preparation.previous_summary,
              )
            else
              "No prior history."
            end
          prefix = generate_turn_prefix_summary(
            preparation.turn_prefix_messages, llm: llm,
            reserve_tokens: preparation.settings.reserve_tokens,
          )
          "#{history}\n\n---\n\n**Turn Context (split turn):**\n\n#{prefix}"
        else
          generate_summary(
            preparation.messages_to_summarize, llm: llm,
            reserve_tokens: preparation.settings.reserve_tokens,
            custom_instructions: custom_instructions,
            previous_summary: preparation.previous_summary,
          )
        end

      lists = compute_file_lists(preparation.modified_files)
      summary += format_file_operations(lists[:read_files], lists[:modified_files])

      {
        summary: summary,
        tokens_before: preparation.tokens_before,
        read_files: lists[:read_files],
        modified_files: lists[:modified_files],
      }
    end

    # ------------------------------------------------------------------
    # Branch summarization (branch-summarization.ts:190-359)
    # ------------------------------------------------------------------

    # prepareBranchEntries: walk NEWEST to OLDEST under the token budget,
    # keeping recent context; tool results are skipped (context is in the
    # assistant's tool call); summary messages (compaction/branch wrappers)
    # squeeze in when under 90% of the budget. Modified files are collected
    # from ALL entries regardless of budget (cumulative tracking).
    def self.prepare_branch_entries(messages, token_budget)
      modified_files = extract_modified_files(messages)
      kept = []
      total = 0
      (messages.length - 1).downto(0) do |i|
        message = messages[i]
        next if message.role == :tool || message.role == :system

        tokens = estimate_tokens(message)
        if token_budget.positive? && total + tokens > token_budget
          if summary_message?(message) && total < token_budget * 0.9
            kept.unshift(message)
            total += tokens
          end
          break
        end

        kept.unshift(message)
        total += tokens
      end
      { messages: kept, modified_files: modified_files, total_tokens: total }
    end

    def self.summary_message?(message)
      content = message.content.to_s
      content.start_with?(SUMMARY_PREFIX) || content.start_with?(BRANCH_SUMMARY_PREFIX)
    end

    # generateBranchSummary: budget = context_window - reserve_tokens (128000
    # fallback); one user-role call with maxTokens 2048; preamble prepended;
    # file lists appended. custom_instructions join as "Additional focus:".
    def self.generate_branch_summary(messages, llm:, context_window:, reserve_tokens: 16_384, custom_instructions: nil)
      budget = (context_window || 128_000) - reserve_tokens
      prepared = prepare_branch_entries(messages, budget)
      return { summary: "No content to summarize" } if prepared[:messages].empty?

      instructions = Prompts.load("branch_summarize")
      instructions = "#{instructions}\n\nAdditional focus: #{custom_instructions}" if custom_instructions
      prompt = "<conversation>\n#{serialize_conversation(prepared[:messages])}\n</conversation>\n\n#{instructions}"
      summary = llm.call(system: Prompts.load("compact_summarize_system"), user: prompt, max_tokens: 2048)

      summary = BRANCH_SUMMARY_PREAMBLE + summary
      lists = compute_file_lists(prepared[:modified_files])
      summary += format_file_operations(lists[:read_files], lists[:modified_files])
      {
        summary: summary.empty? ? "No summary generated" : summary,
        read_files: lists[:read_files],
        modified_files: lists[:modified_files],
      }
    end
  end
end

__END__

require "brute/messages"

describe "prime_agent/compaction" do
  C = PrimeAgent::Compaction
  SETTINGS = C::DEFAULT_SETTINGS

  describe ".estimate_tokens" do
    it "counts chars/4 for user and tool messages" do
      C.estimate_tokens(Brute::Message.new(role: :user, content: "x" * 40)).should == 10
      C.estimate_tokens(Brute::Message.new(role: :tool, content: "x" * 41)).should == 11 # ceil
    end

    it "counts assistant content plus tool call name and JSON arguments" do
      calls = [{ id: "1", name: "iruby", arguments: { "code" => "puts 1" } }]
      C.estimate_tokens(Brute::Message.new(role: :assistant, content: "x" * 8, tool_calls: calls)).should ==
        ((8 + "iruby".length + JSON.generate({ "code" => "puts 1" }).length) / 4.0).ceil
    end

    it "ignores system messages" do
      C.estimate_tokens(Brute::Message.new(role: :system, content: "x" * 400)).should == 0
    end
  end

  describe ".estimate_context_tokens" do
    it "sums estimates over every message when no usage is available" do
      messages = [Brute::Message.new(role: :user, content: "x" * 40), Brute::Message.new(role: :assistant, content: "y" * 40)]
      estimate = C.estimate_context_tokens(messages)
      estimate.tokens.should == 20
      estimate.usage_tokens.should == 0
      estimate.last_usage_index.should.be.nil
    end

    it "uses the last assistant usage and estimates only the trailing tail" do
      with_usage = Class.new do
        attr_reader :role, :content, :tool_calls, :usage

        def initialize(usage)
          @role = :assistant
          @content = "y" * 40
          @tool_calls = nil
          @usage = usage
        end
      end.new({ total: 500 })
      messages = [Brute::Message.new(role: :user, content: "x" * 40), with_usage, Brute::Message.new(role: :tool, content: "z" * 40)]
      estimate = C.estimate_context_tokens(messages)
      estimate.tokens.should == 510
      estimate.usage_tokens.should == 500
      estimate.trailing_tokens.should == 10
      estimate.last_usage_index.should == 1
    end
  end

  describe ".should_compact?" do
    it "fires past context_window - reserve_tokens and honors the guards" do
      C.should_compact?(151, 200, C::Settings.new(enabled: true, reserve_tokens: 50, keep_recent_tokens: 10)).should.be.true
      C.should_compact?(149, 200, C::Settings.new(enabled: true, reserve_tokens: 50, keep_recent_tokens: 10)).should.be.false
      C.should_compact?(100, 0, SETTINGS).should.be.false   # no window -> never
      C.should_compact?(1000, 200, C::Settings.new(enabled: false, reserve_tokens: 50, keep_recent_tokens: 10)).should.be.false
    end
  end

  describe ".find_cut_point" do
    # [system, user, assistant, tool, user, assistant] — sizes chosen so the
    # budget crosses at the big tool result.
    def log
      [
        Brute::Message.new(role: :system, content: "s"),
        Brute::Message.new(role: :user, content: "u1 #{"u" * 40}"),
        Brute::Message.new(role: :assistant, content: "a1 #{"a" * 40}"),
        Brute::Message.new(role: :tool, content: "t1 #{"t" * 400}"),
        Brute::Message.new(role: :user, content: "u2"),
        Brute::Message.new(role: :assistant, content: "a2"),
      ]
    end

    it "cuts at the closest valid point at/after the budget crossing, never at a tool result" do
      cut = C.find_cut_point(log, 0, 6, 20)
      cut.first_kept_index.should == 4 # the u2 user message
      cut.split_turn?.should.be.false
    end

    it "marks a mid-turn cut as a split turn with its turn start" do
      messages = log
      messages.delete_at(4) # drop u2 so the cut lands on the trailing assistant
      cut = C.find_cut_point(messages, 0, 5, 20)
      cut.split_turn?.should.be.true
      cut.turn_start_index.should == 1 # u1 starts the turn
    end

    it "keeps everything when the log fits" do
      cut = C.find_cut_point(log, 0, 6, 1_000_000)
      cut.first_kept_index.should == 1 # first valid cut point (u1; system is never one)
    end
  end

  describe ".serialize_conversation" do
    it "renders the [User]/[Assistant]/[Tool result] text form, truncating tool results" do
      calls = [{ id: "1", name: "iruby", arguments: { "code" => "x = 1" } }]
      out = C.serialize_conversation([
        Brute::Message.new(role: :system, content: "not serialized"),
        Brute::Message.new(role: :user, content: "hi"),
        Brute::Message.new(role: :assistant, content: "working", tool_calls: calls),
        Brute::Message.new(role: :tool, content: "r" * 3000),
      ])
      out.should.not.include "not serialized"
      out.should.include "[User]: hi"
      out.should.include "[Assistant]: working"
      out.should.include %Q{[Assistant tool calls]: iruby(code="x = 1")}
      out.should.include "[... 1000 more characters truncated]"
    end
  end

  describe ".build_summarization_prompt" do
    it "uses the update template with a previous summary and wraps instructions" do
      plain = C.build_summarization_prompt
      plain.should.include "a conversation to summarize"
      plain.should.include "IRuby kernel keeps running"

      updated = C.build_summarization_prompt(previous_summary: "OLD", custom_instructions: "keep tests")
      updated.should.include "NEW conversation messages"
      updated.should.include "<user-instructions>"
      updated.should.include "keep tests"
    end
  end

  describe ".prepare_compaction + .compact" do
    def settings(keep: 20)
      C::Settings.new(enabled: true, reserve_tokens: 100, keep_recent_tokens: keep)
    end

    def big_log
      [
        Brute::Message.new(role: :system, content: "s"),
        Brute::Message.new(role: :user, content: "u1"),
        Brute::Message.new(role: :assistant, content: "a1 #{"a" * 400}"),
        Brute::Message.new(role: :tool, content: "t1 #{"t" * 400}"),
        Brute::Message.new(role: :user, content: "u2"),
        Brute::Message.new(role: :assistant, content: "a2"),
      ]
    end

    it "prepares the region between the previous boundary and the cut" do
      prep = C.prepare_compaction(big_log, settings: settings)
      prep.messages_to_summarize.map(&:content).should == ["u1", "a1 #{"a" * 400}", "t1 #{"t" * 400}"]
      prep.first_kept_index.should == 4
      prep.split_turn?.should.be.false
      prep.previous_summary.should.be.nil
      prep.tokens_before.should.be > 0
    end

    it "returns nil when the log fits and there is no previous summary" do
      C.prepare_compaction(big_log, settings: settings(keep: 1_000_000)).should.be.nil
    end

    it "generates the summary, appends file lists, and honors custom instructions" do
      log = big_log
      log[3] = Brute::Message.new(role: :tool, content: "Edited /x.rb\ndiff /x.rb:1\n- a\n+ b")
      log[4] = Brute::Message.new(role: :user, content: "u2 #{"u" * 400}") # big user keeps the cut on a turn boundary
      prep = C.prepare_compaction(log, settings: settings)
      prep.split_turn?.should.be.false
      calls = []
      llm = lambda do |system:, user:, max_tokens:|
        calls << user
        "summary text"
      end
      result = C.compact(prep, llm: llm, custom_instructions: "focus")
      result[:summary].should.include "summary text"
      result[:summary].should.include "<modified-files>"
      result[:summary].should.include "/x.rb"
      calls.first.should.include "<user-instructions>"
    end

    it "splits a turn with a turn-prefix summary at half budget" do
      log = [
        Brute::Message.new(role: :system, content: "s"),
        Brute::Message.new(role: :user, content: "u0"),
        Brute::Message.new(role: :assistant, content: "a0 #{"a" * 400}"),
        Brute::Message.new(role: :user, content: "u1"),
        Brute::Message.new(role: :assistant, content: "a1"),
        Brute::Message.new(role: :tool, content: "t1 #{"t" * 400}"),
        Brute::Message.new(role: :assistant, content: "a2"),
      ]
      prep = C.prepare_compaction(log, settings: settings)
      prep.split_turn?.should.be.true
      prep.turn_start_index.should == 3
      prep.messages_to_summarize.map(&:role).should == [:user, :assistant]
      budgets = []
      llm = ->(system:, user:, max_tokens:) { budgets << max_tokens; "S" }
      result = C.compact(prep, llm: llm)
      result[:summary].should.include "**Turn Context (split turn):**"
      budgets.max.should == 80  # history: 0.8 * 100
      budgets.min.should == 50  # turn prefix: 0.5 * 100
    end

    it "carries the previous summary and file lists across compactions" do
      first = C.prepare_compaction(big_log, settings: settings)
      summary_msg = Brute::Message.new(role: :user, content: "#{C::SUMMARY_PREFIX}FIRST#{C::SUMMARY_SUFFIX}")
      kept = big_log[first.first_kept_index..]
      log = [big_log[0], summary_msg] + kept
      boundary = { summary: "FIRST", summary_message: summary_msg,
                   first_kept_message: kept.first, modified_files: ["/old.rb"] }

      log.insert(-1, Brute::Message.new(role: :user, content: "u3 #{"u" * 400}"))
      prep = C.prepare_compaction(log, settings: settings, boundary: boundary)
      prep.previous_summary.should == "FIRST"
      prep.modified_files.should.include "/old.rb"

      result = C.compact(prep, llm: ->(system:, user:, max_tokens:) { "SECOND" })
      result[:modified_files].should == ["/old.rb"]
    end
  end
end
