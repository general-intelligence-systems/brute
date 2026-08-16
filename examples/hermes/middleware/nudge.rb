# frozen_string_literal: true

require "json"
require "fileutils"

module Hermes
  module Middleware
    # Nudge — the learning loop's cadence mechanism (per-turn middleware).
    # Port of hermes-agent: agent/turn_context.py:685 (memory), conversation_loop.py:1776
    # (skill counter), tool_executor.py:605-608 (use-resets), turn_finalizer.py:733 (check).
    #
    # A nudge is NOT a message — nothing is injected into the conversation. Two
    # counters gate the after-turn background review fork:
    #
    #   Memory nudge — unit: user turns. Checked at turn SETUP: counter >=
    #   interval -> env[:review_memory] = true, counter resets.
    #
    #   Skill nudge — unit: tool-calling iterations (env[:current_iteration]
    #   delta across the turn). Checked at turn END: counter >= interval ->
    #   env[:review_skills] = true, counter resets.
    #
    #   Both counters reset on actual tool use (memory / skill_manage) —
    #   the nudge is "you haven't persisted knowledge lately", and using the
    #   tools IS the persistence.
    #
    #   This process is single-shot (systemd-timer model), so the counters
    #   are DURABLE: with state_path given they load from disk at first turn
    #   and persist after every turn. Without a state file (or on first run)
    #   the memory counter hydrates from conversation history
    #   (prior_user_turns % interval) — hermes' resume behavior.
    #
    # BackgroundReview reads the flags after the turn — so Nudge must sit
    # INNER of it (closer to the loop): after-phases unwind inside-out, and
    # Nudge's after-phase sets :review_skills before BackgroundReview's runs.
    class Nudge
      def initialize(app, memory_interval: 10, skill_interval: 10, state_path: nil)
        @app = app
        @memory_interval = memory_interval
        @skill_interval = skill_interval
        @turns_since_memory = 0
        @iters_since_skill = 0
        @state_path = state_path
        @loaded = false
      end

      def call(env)
        load_state_once(env)

        # Memory nudge — turn setup.
        @turns_since_memory += 1
        if @memory_interval.positive? && memory_available?(env) && @turns_since_memory >= @memory_interval
          env[:review_memory] = true
          @turns_since_memory = 0
        end

        iterations_before = env[:current_iteration] || 1
        @app.call(env)

        # Use-resets (hermes tool_executor.py:605-608).
        used = tool_names_used(env)
        @turns_since_memory = 0 if used.include?("memory")
        @iters_since_skill = 0 if used.include?("skill_manage")

        # Skill nudge — turn end.
        @iters_since_skill += (env[:current_iteration] || 1) - iterations_before
        if @skill_interval.positive? && !used.include?("skill_manage") &&
           skills_available?(env) && @iters_since_skill >= @skill_interval
          env[:review_skills] = true
          @iters_since_skill = 0
        end

        save_state
        env
      end

      private

      # Durable counters (timer-model): prefer the state file; hydrate from
      # history only when there isn't one.
      def load_state_once(env)
        return if @loaded

        @loaded = true
        data = read_state
        if data
          @turns_since_memory = data["turns_since_memory"] || 0
          @iters_since_skill = data["iters_since_skill"] || 0
        else
          hydrate_from_history(env)
        end
      end

      def hydrate_from_history(env)
        prior_user_turns = env[:messages].count { |m| m.role == :user }
        # The current turn's user message is already in the log; hermes seeds
        # from history BEFORE this turn's message is counted, so subtract it.
        prior_user_turns -= 1 if prior_user_turns.positive?
        if @memory_interval.positive? && prior_user_turns.positive?
          @turns_since_memory = prior_user_turns % @memory_interval
        end
      end

      def read_state
        return nil unless @state_path && File.exist?(@state_path)

        JSON.parse(File.read(@state_path, encoding: Encoding::UTF_8))
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def save_state
        return unless @state_path

        FileUtils.mkdir_p(File.dirname(@state_path))
        tmp = "#{@state_path}.tmp"
        File.write(tmp, JSON.dump({
          "turns_since_memory" => @turns_since_memory,
          "iters_since_skill" => @iters_since_skill,
        }), encoding: Encoding::UTF_8)
        File.rename(tmp, @state_path)
      rescue SystemCallError, IOError
        nil # cadence loss is recoverable; never break a turn over it
      end

      def memory_available?(env)
        !env[:memory_store].nil?
      end

      def skills_available?(env)
        tool_names(env).include?("skill_manage")
      end

      def tool_names(env)
        Array(env[:tools]).map { |t| t.respond_to?(:name) ? t.name.to_s : t[:name].to_s }
      end

      def tool_names_used(env)
        Array(env[:events])
          .select { |e| e.is_a?(Hash) && e[:type] == :tool_result }
          .map { |e| e.dig(:data, :name).to_s }
      end
    end
  end
end

