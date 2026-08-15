# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"

module Hermes
  # Write-approval gate for memory (and later skills) writes — full port of
  # hermes-agent tools/write_approval.py.
  #
  # The gate only ever DELAYS a write for approval — it never silently refuses
  # one. Decision matrix:
  #   gate off (default)                  → allow (writes flow freely)
  #   gate on, skills or background origin → stage
  #   gate on, memory + interactive       → inline approve/deny prompt
  #   gate on, no interactive channel     → stage
  #
  # Staged writes persist under <pending_root>/<subsystem>/<id>.json and are
  # replayed via apply_pending after user review.
  module WriteApproval
    MEMORY = "memory"
    SKILLS = "skills"
    SUBSYSTEMS = [MEMORY, SKILLS].freeze

    # Exactly one of allow/blocked/stage is true.
    GateDecision = Struct.new(:allow, :blocked, :stage, :message, keyword_init: true)

    class << self
      # Per-subsystem gate flags (default: off everywhere).
      def flags
        @flags ||= Hash.new(false)
      end

      # Inline approval callback: ->(summary, detail) { true / false / nil }.
      # nil means "no decision" (prompt failed/unavailable) → stage instead.
      attr_accessor :approval_callback

      # Root dir for staged writes (default: ./pending).
      def pending_root
        @pending_root ||= File.join(Dir.pwd, "pending")
      end
      attr_writer :pending_root

      def enabled?(subsystem)
        SUBSYSTEMS.include?(subsystem) && !!flags[subsystem]
      end

      # The active write origin: "foreground" or "background_review"
      # (thread-local; the review fork sets it when it runs).
      def current_origin
        Thread.current[:hermes_write_origin] || "foreground"
      end

      def current_origin=(origin)
        Thread.current[:hermes_write_origin] = origin
      end

      def background?
        current_origin == "background_review"
      end

      def evaluate_gate(subsystem, inline_summary: "", inline_detail: "")
        return GateDecision.new(allow: true) unless enabled?(subsystem)

        # Skills always stage (too big to review inline); background writes
        # stage too (daemon thread, no user present).
        if subsystem == SKILLS || background?
          return GateDecision.new(
            stage: true,
            message: "Staged for approval (#{subsystem}.write_approval is on). " \
                     "Not yet saved — review with /#{subsystem} pending.",
          )
        end

        # Memory + foreground: prompt inline when a channel exists.
        if approval_callback
          granted = begin
            approval_callback.call(inline_summary, inline_detail)
          rescue StandardError
            nil # a crashed prompt falls back to staging, never a silent drop
          end
          return GateDecision.new(allow: true) if granted == true
          if granted == false
            return GateDecision.new(
              blocked: true,
              message: "Memory write denied by user. The change was not saved.",
            )
          end
        end

        GateDecision.new(
          stage: true,
          message: "Staged for approval (memory.write_approval is on). " \
                   "Not yet saved — review with /memory pending.",
        )
      end

      # Persist a pending write and return its record. Best-effort: on disk
      # failure the record is still returned without a persisted file (the
      # write is simply lost — the safe failure for an approval gate).
      def stage_write(subsystem, payload, summary:, origin:)
        id = SecureRandom.hex(4)
        record = {
          "id" => id,
          "subsystem" => subsystem,
          "action" => payload["action"].to_s,
          "summary" => summary.to_s.strip,
          "origin" => origin.to_s.empty? ? "foreground" : origin.to_s,
          "created_at" => Time.now.to_f,
          "payload" => payload,
        }
        begin
          dir = File.join(pending_root, subsystem)
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{id}.json")
          tmp = "#{path}.tmp"
          File.write(tmp, JSON.pretty_generate(record), encoding: Encoding::UTF_8)
          File.rename(tmp, path)
        rescue SystemCallError, IOError
          # lost write is the safe failure — see hermes note
        end
        record
      end

      # All pending records for a subsystem, oldest first.
      def list_pending(subsystem)
        dir = File.join(pending_root, subsystem)
        return [] unless Dir.exist?(dir)

        Dir[File.join(dir, "*.json")].filter_map do |path|
          JSON.parse(File.read(path, encoding: Encoding::UTF_8))
        rescue JSON::ParserError, SystemCallError
          nil
        end.sort_by { |r| r["created_at"] || 0 }
      end

      def get_pending(subsystem, id)
        path = File.join(pending_root, subsystem, "#{id}.json")
        return nil unless File.exist?(path)

        JSON.parse(File.read(path, encoding: Encoding::UTF_8))
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def discard_pending(subsystem, id)
        path = File.join(pending_root, subsystem, "#{id}.json")
        return false unless File.exist?(path)

        File.delete(path)
        true
      end

      def pending_count(subsystem)
        list_pending(subsystem).size
      end
    end
  end
end
