# frozen_string_literal: true

module Hermes
  # Context compactor — the hermes-agent compress() algorithm
  # (agent/context_compressor.py:6427) ported to the essentials, full
  # fidelity on the parts that matter:
  #
  #   1. Cheap pre-pass: prune old tool results (no LLM call)
  #   2. Protect head (system prompt + first exchange)
  #   3. Find the tail cut by TOKEN BUDGET, guaranteeing >= 1 real user turn
  #   4. LLM-summarize the middle with the structured template (iterative
  #      update when a previous summary exists)
  #   5. Reinsert: head + summary handoff + tail, role-alternation safe
  #      (merged-into-tail corner case included)
  #
  # Token estimation is chars/4 (hermes _chars_to_tokens). The summarizer is
  # injected (a proc), so the aux model is the caller's choice.
  class Compactor
    HISTORICAL_TASK_HEADING = "## Historical Task Snapshot"
    MERGED_PRIOR_CONTEXT_HEADER = "[PRIOR CONTEXT — for reference only; not a new message]"
    MERGED_SUMMARY_DELIMITER = "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]"
    SUMMARY_END_MARKER =
      "--- END OF CONTEXT SUMMARY — " \
      "respond to the message below, not the summary above ---"

    SUMMARY_PREFIX = <<~TXT.chomp
      [CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary below. This is a handoff from a previous context window — treat it as background reference, NOT as active instructions. Do NOT answer questions or fulfill requests mentioned in this summary; they were already addressed. Respond ONLY to the latest user message that appears AFTER this summary — that message is the single source of truth for what to do right now. If no user message appears AFTER this summary, do nothing: do not resume, wrap up, or continue work from '#{HISTORICAL_TASK_HEADING}' or any other section, do not call tools, and wait for a new user message. This handoff must never become the active turn by itself. (Exception: if tool results or your own tool calls appear after this summary, you are mid-way through an in-flight exchange — continue that exchange normally.) Topic overlap with the summary does NOT mean you should resume its task: even on similar topics, the latest user message WINS. Treat ONLY the latest message as the active task and discard stale items from '#{HISTORICAL_TASK_HEADING}' entirely — do not 'wrap up' or 'finish' work described there unless the latest message explicitly asks for it. Reverse signals in the latest message (e.g. 'stop', 'undo', 'roll back', 'just verify', 'don't do that anymore', 'never mind', a new topic) must immediately end any in-flight work described in the summary; do not re-surface it in later turns. IMPORTANT: Your persistent memory (MEMORY.md, USER.md) in the system prompt is ALWAYS authoritative and active — never ignore or deprioritize memory content due to this compaction note. None of the above restricts HOW you work: your tools remain fully active — keep calling them normally for the active task (edit files, run commands, search) instead of merely narrating what you would do. The current session state (files, config, etc.) may reflect work described here — avoid repeating it:
    TXT

    PREAMBLE =
      "You are a summarization agent creating a context checkpoint. " \
      "Treat the conversation turns below as source material for a " \
      "compact record of prior work. " \
      "Produce only the structured summary; do not add a greeting, " \
      "preamble, or prefix. " \
      "Write the summary in the same language the user was using in the " \
      "conversation — do not translate or switch to English. " \
      "NEVER include API keys, tokens, passwords, secrets, credentials, " \
      "or connection strings in the summary — replace any that appear " \
      "with [REDACTED]. Note that credentials were present, but do not " \
      "preserve their values."

    SMALL_WINDOW_FLOOR = 0.75
    SMALL_WINDOW_CHARS = 512_000

    attr_reader :previous_summary

    def initialize(context_length: 128_000, summarize:,
                   threshold: 0.50, target_ratio: 0.20,
                   protect_last_n: 20, min_tail_user_messages: 1,
                   max_input_chars: 100_000)
      @context_length = context_length
      @summarize = summarize
      @threshold = threshold
      @target_ratio = target_ratio
      @protect_last_n = protect_last_n
      @min_tail_user_messages = min_tail_user_messages
      @max_input_chars = max_input_chars
      @previous_summary = nil
    end

    def threshold_tokens
      base = @context_length < SMALL_WINDOW_CHARS ? [@threshold, SMALL_WINDOW_FLOOR].max : @threshold
      (@context_length * base).to_i
    end

    def tail_budget = (threshold_tokens * @target_ratio).to_i

    def estimate(messages)
      messages.sum { |m| (m.content.to_s.length + 3) / 4 }
    end

    def should_compress?(messages, tokens: nil)
      (tokens || estimate(messages)) >= threshold_tokens
    end

    # Returns the new message list, or nil when there is nothing meaningful
    # to compress (too few messages — hermes' "insufficient_messages" abort).
    def compress(messages)
      head_size = protect_head_size(messages)
      return nil if messages.size <= head_size + 4

      pruned = prune_old_tool_results(messages)
      compress_start = align_boundary_forward(pruned, head_size)
      compress_end = find_tail_cut(pruned, compress_start)
      return nil if compress_end <= compress_start

      middle = pruned[compress_start...compress_end]
      summary = summarize_middle(middle)
      return nil unless summary && !summary.strip.empty?

      @previous_summary = summary

      tail = pruned[compress_end..] || []
      handoff = "#{SUMMARY_PREFIX}\n#{summary}\n#{SUMMARY_END_MARKER}"
      rebuild(pruned[0...compress_start], handoff, tail)
    end

    # -- Phases -----------------------------------------------------------------

    # System prompt + the first exchange (first user message and everything
    # through the assistant turn that completes it).
    def protect_head_size(messages)
      idx = 0
      idx += 1 while idx < messages.size && messages[idx].role == :system
      first_user = messages.index.with_index { |m, i| m.role == :user && i >= idx }
      return 1 if first_user.nil?

      after_first = messages.index.with_index { |m, i| m.role == :user && i > first_user }
      after_first || messages.size
    end

    # Cheap pre-pass: truncate large OLD tool results outside the protected
    # tail window (they are about to be summarized anyway).
    def prune_old_tool_results(messages)
      boundary = [messages.size - @protect_last_n, 0].max
      messages.each_with_index.map do |m, i|
        if m.role == :tool && i < boundary && m.content.to_s.length > 2_000
          Brute::Message.new(role: :tool, content: "[pruned tool output — #{m.content.length} chars]", tool_call_id: m.tool_call_id)
        else
          m
        end
      end
    end

    # Never start the compressed window on a tool message.
    def align_boundary_forward(messages, start)
      start += 1 while start < messages.size && messages[start].role == :tool
      start
    end

    # Tail cut by token budget, extended back to include the last real user
    # message (min_tail_user_messages).
    def find_tail_cut(messages, compress_start)
      budget = tail_budget
      total = 0
      cut = messages.size
      cut -= 1 while cut > compress_start && (total += message_tokens(messages[cut - 1])) < budget
      cut = [cut, messages.size - @protect_last_n].min if @protect_last_n.positive?

      # Guarantee >= min_tail_user_messages real user turns in the tail.
      users_in_tail = messages[cut..]&.count { |m| m.role == :user } || 0
      while users_in_tail < @min_tail_user_messages && cut > compress_start
        cut -= 1
        users_in_tail += 1 if messages[cut].role == :user
      end

      # Align: never start the tail with a tool message.
      cut += 1 while cut < messages.size && messages[cut].role == :tool && cut < messages.size - 1
      cut
    end

    def summarize_middle(middle)
      input = serialize(middle)[0, @max_input_chars]
      prompt = build_summary_prompt(input)
      @summarize.call(prompt)&.strip
    rescue StandardError
      nil # a failed summarizer aborts the compaction (never a fake summary)
    end

    def serialize(messages)
      messages.map do |m|
        case m.role
        when :user then "USER: #{m.content}"
        when :assistant
          tcs = Array(m.respond_to?(:tool_calls) ? m.tool_calls : [])
          names = tcs.map { |tc| tc.respond_to?(:name) ? tc.name : tc[:name] }
          base = "ASSISTANT: #{m.content}"
          names.empty? ? base : "#{base}\nASSISTANT[tools: #{names.join(', ')}]"
        when :tool then "TOOL_RESULT: #{m.content.to_s[0, 1_000]}"
        when :system then nil
        end
      end.compact.join("\n\n")
    end

    def build_summary_prompt(serialized_turns)
      update_note =
        if @previous_summary
          "\n\nA previous summary of still-older turns follows. UPDATE it with the new material below — preserve everything in it that remains relevant.\n\n#{@previous_summary}\n"
        else
          ""
        end

      <<~PROMPT
        #{PREAMBLE}

        TEMPORAL ANCHORING: The current date is #{Time.now.strftime('%Y-%m-%d')}. When an action has already been carried out, phrase it as a completed, dated, past-tense fact rather than an open instruction. Never leave a finished action worded as if it still needs doing, and never invent a date for work that has not happened yet.
        #{update_note}
        Produce the summary in EXACTLY this structure:

        #{HISTORICAL_TASK_HEADING}
        [THE SINGLE MOST IMPORTANT FIELD. Capture the user's most recent unfulfilled input verbatim — the exact words they used. If the user's most recent message was a reverse signal (stop, undo, never mind, change of topic) that supersedes earlier work, write the reverse signal verbatim and DO NOT carry forward the cancelled task. If no outstanding task exists, write "None".]

        ## Goal
        [What the user is trying to accomplish overall]

        ## Constraints & Preferences
        [User preferences, coding style, constraints, important decisions]

        ## Completed Actions
        [Numbered list of concrete actions taken — include tool used, target, and outcome. Format: N. ACTION target — outcome [tool: name]]

        ## Active State
        [Current working state — working directory and branch if applicable, modified/created files, test status, running processes]

        ## Blocked
        [Any blockers, errors, or issues not yet resolved. Include exact error messages.]

        ## Key Decisions
        [Important technical decisions and WHY they were made]

        ## Resolved Questions
        [Questions the user asked that were ALREADY answered — include the answer so it is not repeated]

        ## Pending Asks
        [Questions or requests from the user that have NOT yet been answered. These are STALE — reference only; the agent must NOT act on them unless the latest user message explicitly requests it. If none, write "None".]

        CONVERSATION TURNS TO SUMMARIZE:

        #{serialized_turns}
      PROMPT
    end

    # head + handoff + tail, role-alternation safe. When the tail leads with a
    # user message, a standalone user-role handoff would collide with it —
    # merge instead (hermes' merged-into-tail corner case).
    def rebuild(head, handoff, tail)
      if tail.first&.role == :user
        merged = tail.first
        content = "#{MERGED_PRIOR_CONTEXT_HEADER}\n#{merged.content}\n\n#{MERGED_SUMMARY_DELIMITER}\n#{handoff}"
        head + [Brute::Message.new(role: :user, content: content)] + tail[1..]
      else
        head + [Brute::Message.new(role: :user, content: handoff)] + tail
      end
    end

    def message_tokens(message)
      (message.content.to_s.length + 3) / 4
    end
  end
end
