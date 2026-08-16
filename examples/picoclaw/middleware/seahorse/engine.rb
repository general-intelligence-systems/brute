# frozen_string_literal: true

require_relative "store"
require_relative "../token_estimator"

# Seahorse engine — picoclaw's pkg/seahorse/short_engine.go +
# short_compaction.go + short_assembler.go. SQLite-backed hierarchical
# context: messages ingest as context_items; assembly keeps a protected
# 32-item fresh tail and walks summaries/messages under the token budget;
# compaction folds the oldest contiguous message chunk into a leaf summary
# (LLM) and summaries into condensed ones, looping until under budget.
module Seahorse
  class Engine
    FRESH_TAIL = 32
    LEAF_MIN_FANOUT = 8
    CONDENSED_MIN_FANOUT = 4
    CONDENSED_MIN_FANOUT_HARD = 2
    LEAF_CHUNK_TOKENS = 20_000
    LEAF_TARGET_TOKENS = 1200
    CONDENSED_TARGET_TOKENS = 2000
    MAX_COMPACT_ITERATIONS = 20
    CONTEXT_THRESHOLD = 0.75

    LEAF_PROMPT = <<~PROMPT
      You summarize a SEGMENT of a conversation for future model turns.
      Treat this as incremental memory compaction input, not a full-conversation summary.

      Normal summary policy:
      - Preserve key decisions, rationale, constraints, and active tasks.
      - Keep essential technical details needed to continue work safely.
      - Remove obvious repetition and conversational filler.

      Output requirements:
      - Plain text only.
      - No preamble, headings, or markdown formatting.
      - Track file operations (created, modified, deleted, renamed) with file paths and current status.
      - If no file operations appear, include exactly: "Files: none".
      - End with exactly: "Expand for details about: <comma-separated list of what was dropped or compressed>".
      - Target length: about %<target>d tokens or less.

      <previous_context>
      %<previous>s
      </previous_context>

      <conversation_segment>
      %<segment>s
      </conversation_segment>
    PROMPT

    CONDENSED_PROMPT = <<~PROMPT
      You condense multiple summaries into a single higher-level summary.
      Preserve all important decisions, constraints, and outcomes.
      Merge overlapping topics. Keep technical details intact.

      Output requirements:
      - Plain text only.
      - No preamble, headings, or markdown formatting.
      - End with exactly: "Expand for details about: <comma-separated list>".
      - Target length: about %<target>d tokens or less.

      <summaries>
      %<segment>s
      </summaries>
    PROMPT

    attr_reader :store

    def initialize(db_path:, summarize:)
      @store = Store.new(db_path)
      @summarize = summarize # proc(prompt) => String, injected LLM call
    end

    def close = @store.close

    # --- ingest (Ingest port: messages + parts + context items) -----------------

    def ingest(session_key, messages)
      conv = @store.conversation_id(session_key)
      messages.each do |message|
        next if message.role.to_sym == :system # system is never ingested

        parts = parts_for(message)
        @store.add_message(conv, role: message.role.to_s,
                                 content: message.content.to_s,
                                 token_count: TokenEstimator.message_tokens(message),
                                 parts: parts)
      end
    end

    def clear(session_key)
      @store.delete_conversation(@store.conversation_id(session_key))
    end

    def tokens(session_key) = @store.context_token_count(@store.conversation_id(session_key))

    def parts_for(message)
      parts = []
      parts << { type: "text", text: message.content.to_s } unless message.content.to_s.empty?
      message.tool_calls.to_a.each do |tc|
        parts << { type: "tool_use", name: tc.name, arguments: tc.arguments.to_json,
                   tool_call_id: tc.id }
      end
      parts << { type: "tool_result", tool_call_id: message.tool_call_id } if message.tool_call_id
      parts
    end

    # --- assemble (budget → summaries + fresh tail) ----------------------------

    def assemble(session_key, budget:)
      conv = @store.conversation_id(session_key)
      items = @store.context_items(conv)
      return { messages: [], summary: "" } if items.empty?

      resolved = items.map { |item| [item, @store.resolve_item(item)] }.reject { |_, r| r.nil? }
      tail_start = [resolved.size - FRESH_TAIL, 0].max
      evictable = resolved[0...tail_start]
      fresh_tail = resolved[tail_start..] || []

      tail_tokens = sum_tokens(fresh_tail)
      if tail_tokens > budget
        fresh_tail, tail_tokens = trim_fresh_tail(fresh_tail, budget)
      end
      remaining = [budget - tail_tokens, 0].max

      selected =
        if sum_tokens(evictable) <= remaining
          evictable
        else
          kept = []
          accum = 0
          evictable.reverse_each do |entry|
            tokens = entry[0]["token_count"]
            break if accum + tokens > remaining

            kept.unshift(entry)
            accum += tokens
          end
          kept
        end

      final = selected + fresh_tail
      messages = []
      summary_parts = []
      max_depth = 0
      condensed = 0
      final.each do |item, record|
        if item["item_type"] == "message"
          messages << record_to_message(record)
        else
          max_depth = [max_depth, record["depth"]].max
          condensed += 1 if record["kind"] == "condensed"
          summary_parts << format_summary_xml(record, @store.summary_parents(record["summary_id"]))
        end
      end

      summary = summary_parts.reject(&:empty?).join("\n\n")
      unless summary.empty?
        summary += "\n\n" unless summary.empty?
        summary +=
          if max_depth >= 2 || condensed >= 2
            "Your context has been heavily compressed through multi-level summarization.\n" \
            "- Do NOT assert specific facts (commands, SHAs, paths, timestamps) from summaries without expanding.\n" \
            "- When uncertain, use expand to recover original detail before making claims.\n" \
            "- Tool escalation: grep → describe → expand"
          else
            "Some earlier messages have been summarized. Use expand tools to recover details if needed."
          end
      end

      { messages: messages, summary: summary }
    end

    # Oldest-end trim at provider-safe boundaries; the active (last user) turn
    # is never split.
    def trim_fresh_tail(tail, budget)
      tokens = sum_tokens(tail)
      return [tail, tokens] if tokens <= budget

      latest = tail.rindex { |_, r| r.is_a?(Hash) && r["role"] == "user" }
      if latest
        turn_tokens = sum_tokens(tail[latest..])
        return [tail[latest..], turn_tokens] if turn_tokens > budget
      end

      start = 0
      while tokens > budget && start < tail.size
        tokens -= tail[start][0]["token_count"]
        start += 1
      end
      start += 1 while start < tail.size && !provider_safe_start?(tail[start..])
      [tail[start..] || [], sum_tokens(tail[start..] || [])]
    end

    def provider_safe_start?(entries)
      entries.each do |item, record|
        next unless item["item_type"] == "message" && record
        return false if record["role"] == "tool"
        return false if record["role"] == "assistant" && record["parts"].any? { |p| p["type"] == "tool_use" }

        return true
      end
      true
    end

    # --- compaction ---------------------------------------------------------------

    def needs_compaction?(session_key, window:)
      tokens(session_key) > window * CONTEXT_THRESHOLD
    end

    def compact_until_under(session_key, budget)
      created = []
      MAX_COMPACT_ITERATIONS.times do
        return created if tokens(session_key) <= budget

        id = compact_leaf(session_key, force: true)
        id ||= compact_condensed(session_key)
        break if id.nil? # no progress

        created << id
      end
      created
    end

    # compactLeaf port: oldest contiguous message chunk outside the fresh tail.
    def compact_leaf(session_key, force: false)
      conv = @store.conversation_id(session_key)
      items = @store.context_items(conv)
      messages = items.select { |i| i["item_type"] == "message" }
      count = messages.size
      total = messages.sum { |i| i["token_count"] }
      return nil if count < LEAF_MIN_FANOUT && total < LEAF_CHUNK_TOKENS

      tail_start = force ? items.size : [items.size - FRESH_TAIL, 0].max
      chunk = []
      accum = 0
      items[0...tail_start].each do |item|
        if item["item_type"] == "message"
          chunk << item
          accum += item["token_count"]
          break if accum >= LEAF_CHUNK_TOKENS
        else
          if chunk.size >= LEAF_MIN_FANOUT
            break
          else
            chunk = []
            accum = 0
          end
        end
      end
      return nil if chunk.size < LEAF_MIN_FANOUT

      records = chunk.map { |i| @store.message(i["message_id"]) }
      prior = []
      idx = items.index(chunk.first) - 1
      while idx >= 0 && prior.size < 2
        if items[idx]["item_type"] == "summary"
          sum = @store.summary(items[idx]["summary_id"])
          prior.unshift(sum["content"]) if sum
        end
        idx -= 1
      end

      segment = records.map { |r| "#{r["role"]}: #{r["content"]}" }.join("\n")
      prompt = format(LEAF_PROMPT, target: LEAF_TARGET_TOKENS, previous: prior.join("\n"), segment: segment)
      content = call_summarizer(prompt) || truncate_summary(records)

      summary_id = @store.create_summary(
        conv, kind: "leaf", depth: 0, content: content,
        token_count: content.length * 2 / 5,
        earliest_at: records.first["created_at"], latest_at: records.last["created_at"],
        source_message_tokens: chunk.sum { |i| i["token_count"] },
      )
      @store.link_summary_to_messages(summary_id, records.map { |r| r["message_id"] })
      @store.replace_context_range_with_summary(conv, chunk.first["ordinal"], chunk.last["ordinal"],
                                                summary_id, content.length * 2 / 5)
      summary_id
    end

    # compactCondensed port: oldest chunk of >=fanout summaries at the
    # shallowest depth present in the context.
    def compact_condensed(session_key)
      conv = @store.conversation_id(session_key)
      items = @store.context_items(conv)

      @store.distinct_depths(conv).each do |depth|
        chunk = []
        items.each do |item|
          next unless item["item_type"] == "summary"

          sum = @store.summary(item["summary_id"])
          next unless sum && sum["depth"] == depth

          chunk << sum
          break if chunk.size >= CONDENSED_MIN_FANOUT
        end
        next if chunk.size < CONDENSED_MIN_FANOUT_HARD

        segment = chunk.map { |s| s["content"] }.join("\n\n")
        prompt = format(CONDENSED_PROMPT, target: CONDENSED_TARGET_TOKENS, segment: segment)
        content = call_summarizer(prompt) || chunk.map { |s| s["content"] }.join("\n")[0, 2048] +
                                            "\n[Condensed from #{chunk.size} summaries]"

        summary_id = @store.create_summary(
          conv, kind: "condensed", depth: depth + 1, content: content,
          token_count: content.length * 2 / 5,
          descendant_count: chunk.size,
          descendant_token_count: chunk.sum { |s| s["token_count"] },
        )
        @store.link_summary_parents(summary_id, chunk.map { |s| s["summary_id"] })
        first = items.find { |i| i["summary_id"] == chunk.first["summary_id"] }
        last = items.find { |i| i["summary_id"] == chunk.last["summary_id"] }
        @store.replace_context_range_with_summary(conv, first["ordinal"], last["ordinal"],
                                                  summary_id, content.length * 2 / 5)
        return summary_id
      end
      nil
    end

    private

    def call_summarizer(prompt)
      result = @summarize.call(prompt).to_s.strip
      result.empty? ? nil : result
    rescue StandardError
      nil
    end

    def truncate_summary(records)
      content = records.map { |r| r["content"].to_s }.join("\n")
      content = content[0, 2048] if content.length > 2048
      "#{content}\n[Truncated from #{records.size} messages]"
    end

    def sum_tokens(entries) = entries.sum { |item, _| item["token_count"] }

    def record_to_message(record)
      parts = record["parts"] || []
      tool_calls = parts.select { |p| p["type"] == "tool_use" }.map do |p|
        { "id" => p["tool_call_id"], "name" => p["name"], "arguments" => JSON.parse(p["arguments"] || "{}") }
      end
      tool_call_id = parts.find { |p| p["type"] == "tool_result" }&.dig("tool_call_id")
      Brute::Message.new(role: record["role"].to_sym, content: record["content"],
                         tool_calls: tool_calls.empty? ? nil : tool_calls, tool_call_id: tool_call_id)
    end

    def escape_xml(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def format_summary_xml(summary, parent_ids)
      attrs = +""
      attrs += %( earliest_at="#{summary["earliest_at"]}") if summary["earliest_at"]
      attrs += %( latest_at="#{summary["latest_at"]}") if summary["latest_at"]

      parents = +""
      if summary["kind"] == "condensed" && parent_ids.any?
        parents = "  <parents>\n"
        parent_ids.each { |pid| parents += %(    <summary_ref id="#{pid}" />\n) }
        parents += "  </parents>\n"
      end

      %(<summary id="#{summary["summary_id"]}" kind="#{summary["kind"]}" depth="#{summary["depth"]}" descendant_count="#{summary["descendant_count"]}"#{attrs}>\n  <content>\n    #{escape_xml(summary["content"])}\n  </content>\n#{parents}</summary>)
    end
  end
end
