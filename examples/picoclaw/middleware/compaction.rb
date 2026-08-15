# frozen_string_literal: true

require "fileutils"
require_relative "token_estimator"

# Compaction — picoclaw's legacy context manager summarization path
# (pkg/agent/context_legacy.go), adapted to brute's pipeline.
#
# Trigger (maybeSummarize port): history size > summarize_message_threshold
# (20) OR estimated history tokens > context_window * summarize_token_percent
# / 100 (75%). The oldest turns are folded into a running summary stored in a
# SIDECAR file (kept out of history) and dropped from history; the prompt
# injects the sidecar on the next turn.
#
# Summarizer (summarizeSession port): keep the last 4 messages; cut at a
# :user boundary; only user/assistant messages are summarized; messages whose
# est. tokens exceed context_window/2 are omitted (noted in the summary);
# >10 valid messages are split at the nearest user message, summarized in two
# batches, then merged by a third call (fallback: concatenation). The LLM call
# retries 3 times (100ms x attempt backoff); total failure falls back to
# deterministic truncation (10% of each message, >=200 runes).
class Compaction
  BATCH_PROMPT_PREFIX = "Provide a concise summary of this conversation segment, " \
                        "preserving core context and key points.\n"
  MERGE_PROMPT = "Merge these two conversation summaries into one cohesive summary:\n\n1: %<first>s\n\n2: %<second>s"
  OMITTED_NOTE = "\n[Note: Some oversized messages were omitted from this summary for efficiency.]"
  MAX_SUMMARIZATION_MESSAGES = 10
  LLM_MAX_RETRIES = 3

  def initialize(app, threshold:, summary_path:, summarize:, token_percent: 75, context_window: nil)
    @app = app
    @threshold = threshold
    @summary_path = summary_path
    @summarize = summarize
    @token_percent = token_percent
    @context_window = context_window.to_i.positive? ? context_window.to_i : 4 * 8192
  end

  def call(env)
    maybe_summarize(env[:messages])
    @app.call(env)
  end

  private

  def maybe_summarize(messages)
    history_size = messages.count { |m| m.role.to_sym != :system }
    estimate = TokenEstimator.messages_tokens(messages)
    token_threshold = @context_window * @token_percent / 100
    return unless history_size > @threshold || estimate > token_threshold

    summarize_session(messages)
  end

  def summarize_session(messages)
    return if messages.size <= 4

    safe_cut = find_safe_boundary(messages, messages.size - 4)
    return if safe_cut <= 0

    keep_count = messages.size - safe_cut
    to_summarize = messages[0...safe_cut]

    max_message_tokens = @context_window / 2
    valid = []
    omitted = false
    to_summarize.each do |msg|
      next unless %i[user assistant].include?(msg.role.to_sym)

      if msg.content.to_s.length / 2 > max_message_tokens
        omitted = true
        next
      end
      valid << msg
    end
    return if valid.empty?

    final =
      if valid.size > MAX_SUMMARIZATION_MESSAGES
        mid = find_nearest_user_message(valid, valid.size / 2)
        first = summarize_batch(valid[0...mid], "")
        second = summarize_batch(valid[mid..], "")
        response = retry_llm(format(MERGE_PROMPT, first: first, second: second))
        response.empty? ? "#{first} #{second}" : response
      else
        summarize_batch(valid, current_summary)
      end

    final += OMITTED_NOTE if omitted && !final.empty?
    return if final.empty?

    FileUtils.mkdir_p(File.dirname(@summary_path))
    File.write(@summary_path, final)
    messages.slice!(0, messages.size - keep_count)
  rescue StandardError => e
    warn "compaction: summarization failed (#{e.class}: #{e.message}); history left intact"
  end

  # summarizeBatch port: LLM summary, deterministic truncation as fallback.
  def summarize_batch(batch, existing_summary)
    prompt = +BATCH_PROMPT_PREFIX
    prompt << "Existing context: #{existing_summary}\n" unless existing_summary.empty?
    prompt << "\nCONVERSATION:\n"
    batch.each { |msg| prompt << "#{msg.role}: #{msg.content}\n" }

    response = retry_llm(prompt)
    return response.strip unless response.empty?

    # Fallback: 10% of each message (>=200 runes), "..." when cut.
    out = +"Conversation summary: "
    batch.each_with_index do |msg, i|
      out << " | " if i.positive?
      chars = msg.content.to_s.strip.chars
      if chars.empty?
        out << "#{msg.role}: "
        next
      end
      keep = [chars.size * 10 / 100, 200].max
      keep = chars.size if keep > chars.size
      out << "#{msg.role}: #{chars.first(keep).join}"
      out << "..." if keep < chars.size
    end
    out
  end

  def retry_llm(prompt)
    LLM_MAX_RETRIES.times do |attempt|
      begin
        response = @summarize.call(prompt)
        return response.to_s unless response.to_s.empty?
      rescue StandardError
        nil
      end
      sleep((attempt + 1) * 0.1) if attempt < LLM_MAX_RETRIES - 1
    end
    ""
  end

  # Snap to a :user boundary so tool-call sequences are never split.
  def find_safe_boundary(messages, target)
    cut = [target, messages.size - 1].min
    cut -= 1 while cut > 0 && messages[cut].role.to_sym != :user
    cut
  end

  def find_nearest_user_message(messages, mid)
    original = mid
    mid -= 1 while mid.positive? && messages[mid].role.to_sym != :user
    return mid if messages[mid]&.role.to_sym == :user

    mid = original
    mid += 1 while mid < messages.size && messages[mid].role.to_sym != :user
    mid < messages.size ? mid : original
  end

  def current_summary
    File.exist?(@summary_path) ? File.read(@summary_path) : ""
  end
end
