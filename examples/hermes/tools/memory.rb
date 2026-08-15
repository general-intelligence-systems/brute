# frozen_string_literal: true

require "json"
require_relative "../write_approval"

module HermesTools
  # memory — durable, cross-session curated memory. Full port of hermes-agent
  # tools/memory_tool.py: the store does the work (Hermes::MemoryStore); this
  # class is the model-facing surface (schema, validation, write gate).
  #
  # The store is injected per turn by Hermes::Middleware::Memory; a storeless
  # instance (e.g. the statically-advertised one) reports unavailable.
  class Memory < Brute::Tool
    description(
      "Save durable facts to persistent memory that survive across sessions. Memory is " \
      "injected into every future turn, so keep entries compact and high-signal.\n\n" \
      "HOW: make ALL your changes in ONE call via an 'operations' array (each item: " \
      "{action, content?, old_text?}). The batch applies atomically and the char limit is " \
      "checked only on the FINAL result — so a single call can remove/replace stale entries " \
      "to free room AND add new ones, even when an add alone would overflow. The response " \
      "reports current/limit chars and confirms completion; one batch call finishes the " \
      "update, so don't repeat it. Use the bare action/content/old_text fields only for a " \
      "single lone change.\n\n" \
      "WHEN: save proactively when the user states a preference, correction, or personal " \
      "detail, or you learn a stable fact about their environment, conventions, or workflow. " \
      "Priority: user preferences & corrections > environment facts > procedures. The best " \
      "memory stops the user repeating themselves.\n\n" \
      "IF FULL: an add is rejected with the current entries shown. Reissue as ONE batch that " \
      "removes or shortens enough stale entries and adds the new one together.\n\n" \
      "TARGETS: 'user' = who the user is (name, role, preferences, style). 'memory' = your " \
      "notes (environment, conventions, tool quirks, lessons).\n\n" \
      "SKIP: trivial/obvious info, easily re-discovered facts, raw data dumps, task progress, " \
      "completed-work logs, temporary TODO state (use session_search for those). Reusable " \
      "procedures belong in a skill, not memory."
    )

    params({
      "type" => "object",
      "properties" => {
        "action" => {
          "type" => "string",
          "enum" => %w[add replace remove],
          "description" => "The action to perform (single-op shape). Omit when using 'operations'.",
        },
        "target" => {
          "type" => "string",
          "enum" => %w[memory user],
          "description" => "Which memory store: 'memory' for personal notes, 'user' for user profile.",
        },
        "content" => {
          "type" => "string",
          "description" => "The entry content. Required for 'add' and 'replace' (single-op shape).",
        },
        "old_text" => {
          "type" => "string",
          "description" => "REQUIRED for 'replace' and 'remove' (single-op shape): a short unique substring identifying the existing entry to modify. Omit only for 'add'.",
        },
        "operations" => {
          "type" => "array",
          "description" => "Batch shape: a list of operations applied atomically in one call " \
                            "against the final char budget. Preferred when making multiple changes " \
                            "or consolidating to make room. Each item is {action, content?, old_text?}.",
          "items" => {
            "type" => "object",
            "properties" => {
              "action" => { "type" => "string", "enum" => %w[add replace remove] },
              "content" => { "type" => "string", "description" => "Entry content for add/replace." },
              "old_text" => { "type" => "string", "description" => "Substring identifying the entry for replace/remove." },
            },
            "required" => ["action"],
          },
        },
      },
      "required" => ["target"],
    })

    def initialize(store = nil)
      @store = store
    end

    def name = "memory"

    def execute(target: "memory", action: nil, content: nil, old_text: nil, operations: nil)
      return err("Memory is not available. It may be disabled in config or this environment.") unless @store

      # Some providers fill optional fields with JSON null — treat as omitted.
      target = "memory" if target.nil?
      return err("Invalid target '#{target}'. Use 'memory' or 'user'.") unless %w[memory user].include?(target)

      # --- Batch path ---
      if operations
        return err("operations must be a list of {action, content?, old_text?} objects.") unless operations.is_a?(Array)

        operations = operations.map { |op| (op || {}).transform_keys(&:to_s) }
        gated = batch_write_gate(target, operations)
        return JSON.dump(gated) if gated

        return JSON.dump(@store.apply_batch(target: target, operations: operations))
      end

      # --- Single-op path: validate BEFORE the gate so an invalid write is
      # rejected immediately instead of staged and only failing at approve time.
      action = action.to_s
      return err("Content is required for 'add' action.") if action == "add" && content.to_s.empty?
      if action == "replace" && (old_text.to_s.empty? || content.to_s.empty?)
        return missing_old_text_error(target, "replace") if old_text.to_s.empty?

        return err("content is required for 'replace' action.")
      end
      return missing_old_text_error(target, "remove") if action == "remove" && old_text.to_s.empty?

      gated = write_gate(action, target, content, old_text)
      return JSON.dump(gated) if gated

      result =
        case action
        when "add"     then @store.add(target: target, content: content)
        when "replace" then @store.replace(target: target, old_text: old_text, content: content)
        when "remove"  then @store.remove(target: target, old_text: old_text)
        else return err("Unknown action '#{action}'. Use: add, replace, remove")
        end

      JSON.dump(result)
    end

    # Replay a staged write directly against the store, bypassing the gate
    # (called by the /memory approve handler).
    def self.apply_pending(payload, store)
      payload = payload.transform_keys(&:to_s)
      action = payload["action"]
      target = payload["target"] || "memory"
      content = payload["content"].to_s
      old_text = payload["old_text"].to_s

      case action
      when "batch"   then store.apply_batch(target: target, operations: payload["operations"] || [])
      when "add"     then store.add(target: target, content: content)
      when "replace" then store.replace(target: target, old_text: old_text, content: content)
      when "remove"  then store.remove(target: target, old_text: old_text)
      else { success: false, error: "Unknown staged action '#{action}'." }
      end
    end

    private

    def err(message)
      JSON.dump("success" => false, "error" => message)
    end

    # replace/remove without old_text: no entry to act on, but a bare error is
    # a dead-end — return the inventory plus an explicit retry instruction.
    def missing_old_text_error(target, action)
      entries = @store.entries_for(target)
      JSON.dump(
        "success" => false,
        "error" => "'#{action}' needs old_text -- a short unique substring of the entry " \
                   "to #{action}. None was provided. Reissue the #{action} with old_text " \
                   "set to part of one of the current_entries below.",
        "current_entries" => entries,
        "usage" => "#{@store.char_count(target)}/#{@store.char_limit(target)}",
      )
    end

    # The write gate. Returns a result hash when the write should NOT proceed
    # (blocked or staged), nil when the caller should perform the real write.
    def write_gate(action, target, content, old_text)
      return nil unless %w[add replace remove].include?(action)

      label = target == "user" ? "user profile" : "memory"
      case action
      when "add"     then summary = "add to #{label}";     detail = content.to_s
      when "replace" then summary = "replace in #{label}"; detail = "old: #{old_text}\nnew: #{content}"
      when "remove"  then summary = "remove from #{label}"; detail = old_text.to_s
      end

      decision = Hermes::WriteApproval.evaluate_gate(
        Hermes::WriteApproval::MEMORY, inline_summary: summary, inline_detail: detail
      )
      return nil if decision.allow
      return { "success" => false, "error" => decision.message } if decision.blocked

      record = Hermes::WriteApproval.stage_write(
        Hermes::WriteApproval::MEMORY,
        { "action" => action, "target" => target, "content" => content, "old_text" => old_text },
        summary: "#{summary}: #{detail[0, 120]}",
        origin: Hermes::WriteApproval.current_origin,
      )
      { "success" => true, "staged" => true, "pending_id" => record["id"], "message" => decision.message }
    end

    # The whole batch is gated as a single unit.
    def batch_write_gate(target, operations)
      label = target == "user" ? "user profile" : "memory"
      summary = "apply #{operations.size} op(s) to #{label}"
      detail = operations.map do |op|
        case op["action"]
        when "remove"  then "- remove: #{op['old_text']}"
        when "replace" then "- replace: #{op['old_text']} -> #{op['content']}"
        else "- #{op['action']}: #{op['content']}"
        end
      end.join("\n")

      decision = Hermes::WriteApproval.evaluate_gate(
        Hermes::WriteApproval::MEMORY, inline_summary: summary, inline_detail: detail
      )
      return nil if decision.allow
      return { "success" => false, "error" => decision.message } if decision.blocked

      record = Hermes::WriteApproval.stage_write(
        Hermes::WriteApproval::MEMORY,
        { "action" => "batch", "target" => target, "operations" => operations },
        summary: "#{summary}: #{detail[0, 120]}",
        origin: Hermes::WriteApproval.current_origin,
      )
      { "success" => true, "staged" => true, "pending_id" => record["id"], "message" => decision.message }
    end
  end
end
