# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Brute
  # Stores session messages as individual JSON files in the OpenCode
  # {info, parts} format. Each session gets a directory; each message
  # is a numbered JSON file inside it.
  #
  # Storage layout:
  #
  #   ~/.brute/sessions/{session-id}/
  #     session.meta.json
  #     msg_0001.json
  #     msg_0002.json
  #     ...
  #
  # Message format matches OpenCode's MessageV2.WithParts:
  #
  #   { info: { id:, sessionID:, role:, time:, ... },
  #     parts: [{ id:, type:, ... }, ...] }
  #
  class MessageStore
    attr_reader :session_id, :dir

    def initialize(session_id:, dir: nil)
      @session_id = session_id
      @dir = dir || File.join(Dir.home, ".brute", "sessions", session_id)
      @messages = {}   # id => { info:, parts: }
      @seq = 0
      @part_seq = 0
      @mutex = Mutex.new
      load_existing
    end

    # ── Append messages ──────────────────────────────────────────────

    # Record a user message.
    def append_user(text:, message_id: nil)
      id = message_id || next_message_id
      msg = {
        info: {
          id: id,
          sessionID: @session_id,
          role: "user",
          time: { created: now_ms },
        },
        parts: [
          { id: next_part_id, sessionID: @session_id, messageID: id,
            type: "text", text: text },
        ],
      }
      save_message(id, msg)
      id
    end

    # Record the start of an assistant message. Returns the message ID.
    # Call complete_assistant later to fill in tokens/timing.
    def append_assistant(message_id: nil, parent_id: nil, model_id: nil, provider_id: nil)
      id = message_id || next_message_id
      msg = {
        info: {
          id: id,
          sessionID: @session_id,
          role: "assistant",
          parentID: parent_id,
          time: { created: now_ms },
          modelID: model_id,
          providerID: provider_id,
          tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
          cost: 0.0,
        },
        parts: [],
      }
      save_message(id, msg)
      id
    end

    # ── Parts ────────────────────────────────────────────────────────

    # Add a text part to an existing message.
    def add_text_part(message_id:, text:)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        part = { id: next_part_id, sessionID: @session_id, messageID: message_id,
                 type: "text", text: text }
        msg[:parts] << part
        persist(message_id)
        part[:id]
      end
    end

    # Add a tool part in "running" state. Returns the part ID.
    def add_tool_part(message_id:, tool:, call_id:, input:)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        part = {
          id: next_part_id, sessionID: @session_id, messageID: message_id,
          type: "tool", callID: call_id, tool: tool,
          state: {
            status: "running",
            input: input,
            time: { start: now_ms },
          },
        }
        msg[:parts] << part
        persist(message_id)
        part[:id]
      end
    end

    # Mark a tool part as completed with output.
    def complete_tool_part(message_id:, call_id:, output:)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        part = msg[:parts].find { |p| p[:type] == "tool" && p[:callID] == call_id }
        return unless part

        part[:state][:status] = "completed"
        part[:state][:output] = output
        part[:state][:time][:end] = now_ms
        persist(message_id)
      end
    end

    # Mark a tool part as errored.
    def error_tool_part(message_id:, call_id:, error:)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        part = msg[:parts].find { |p| p[:type] == "tool" && p[:callID] == call_id }
        return unless part

        part[:state][:status] = "error"
        part[:state][:error] = error.to_s
        part[:state][:time][:end] = now_ms
        persist(message_id)
      end
    end

    # Add a step-finish part to an assistant message.
    def add_step_finish(message_id:, tokens: nil)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        part = {
          id: next_part_id, sessionID: @session_id, messageID: message_id,
          type: "step-finish",
          reason: "stop",
          tokens: tokens || { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
        }
        msg[:parts] << part
        persist(message_id)
      end
    end

    # ── Complete / update ────────────────────────────────────────────

    # Finalize an assistant message with token counts and completion time.
    def complete_assistant(message_id:, tokens: nil)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        msg[:info][:time][:completed] = now_ms
        if tokens
          msg[:info][:tokens] = {
            input: tokens[:input] || tokens[:total_input] || 0,
            output: tokens[:output] || tokens[:total_output] || 0,
            reasoning: tokens[:reasoning] || tokens[:total_reasoning] || 0,
            cache: tokens[:cache] || { read: 0, write: 0 },
          }
        end
        persist(message_id)
      end
    end

    # ── Queries ──────────────────────────────────────────────────────

    # All messages in order.
    def messages
      @mutex.synchronize { @messages.values }
    end

    # Single message by ID.
    def message(id)
      @mutex.synchronize { @messages[id] }
    end

    # Number of stored messages.
    def count
      @mutex.synchronize { @messages.size }
    end

    private

    # ── ID generation ────────────────────────────────────────────────

    def next_message_id
      @seq += 1
      format("msg_%04d", @seq)
    end

    def next_part_id
      @part_seq += 1
      format("prt_%04d", @part_seq)
    end

    def now_ms
      (Time.now.to_f * 1000).to_i
    end

    # ── Persistence ──────────────────────────────────────────────────

    def save_message(id, msg)
      @mutex.synchronize do
        @messages[id] = msg
        persist(id)
      end
    end

    def persist(id)
      FileUtils.mkdir_p(@dir)
      msg = @messages[id]
      return unless msg

      path = File.join(@dir, "#{id}.json")
      File.write(path, JSON.pretty_generate(msg))
    end

    # Load any existing message files from disk on init.
    def load_existing
      return unless File.directory?(@dir)

      Dir.glob(File.join(@dir, "msg_*.json")).sort.each do |path|
        data = JSON.parse(File.read(path), symbolize_names: true)
        id = data.dig(:info, :id)
        next unless id

        @messages[id] = data

        # Track sequence numbers so new IDs don't collide
        if (m = id.match(/\Amsg_(\d+)\z/))
          n = m[1].to_i
          @seq = n if n > @seq
        end

        # Track part sequences too
        (data[:parts] || []).each do |part|
          pid = part[:id]
          if pid.is_a?(String) && (m = pid.match(/\Aprt_(\d+)\z/))
            n = m[1].to_i
            @part_seq = n if n > @part_seq
          end
        end
      end
    end
  end
end
