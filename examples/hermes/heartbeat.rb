# frozen_string_literal: true

require "json"
require "fileutils"

module Hermes
  # Heartbeat — the user-owned recurring instruction (driver-side in the
  # timer model). Port of hermes-agent hermes_cli/heartbeat.py.
  #
  # Config lives at <dir>/heartbeat.json: {interval_seconds, prompt, anchor}.
  # The tick driver calls due?/fired!; the instruction framing (verbatim) is
  # the load-bearing part — "do not invent work" keeps idle turns cheap and
  # honest. Missed ticks coalesce: the anchor resets on fire, never a burst.
  module Heartbeat
    MIN_INTERVAL_SECONDS = 60

    INSTRUCTION =
      "[Heartbeat — recurring instruction, fires every %s]\n" \
      "%s\n\n" \
      "If there is nothing meaningful to do or report for this instruction right " \
      "now, reply briefly that nothing has changed and stop — do not invent work."

    module_function

    def config_path(dir)
      File.join(dir, "heartbeat.json")
    end

    def load(dir:)
      path = config_path(dir)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def set(interval_seconds:, prompt:, dir:)
      interval_seconds = [interval_seconds.to_i, MIN_INTERVAL_SECONDS].max
      FileUtils.mkdir_p(dir)
      tmp = "#{config_path(dir)}.tmp"
      File.write(tmp, JSON.pretty_generate(
        "interval_seconds" => interval_seconds,
        "prompt" => prompt,
        "anchor" => Time.now.to_f,
      ))
      File.rename(tmp, config_path(dir))
      load(dir: dir)
    end

    def clear(dir:)
      File.delete(config_path(dir)) if File.exist?(config_path(dir))
    end

    def due?(dir:, now: Time.now)
      config = load(dir: dir)
      return false unless config

      config["anchor"].to_f + config["interval_seconds"].to_i <= now.to_f
    end

    # Coalesce: anchor resets to now — missed ticks never burst.
    def fired!(dir:, now: Time.now)
      config = load(dir: dir)
      return unless config

      config["anchor"] = now.to_f
      tmp = "#{config_path(dir)}.tmp"
      File.write(tmp, JSON.pretty_generate(config))
      File.rename(tmp, config_path(dir))
    end

    def message(config)
      Kernel.format(INSTRUCTION, interval_text(config["interval_seconds"]), config["prompt"])
    end

    def interval_text(seconds)
      s = seconds.to_i
      return "#{s}s" if s < 3600
      return "#{s / 3600}h" if (s % 3600).zero?
      return "#{s / 86_400}d" if (s % 86_400).zero?

      "#{s}s"
    end
  end
end
