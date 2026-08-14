# frozen_string_literal: true

# OpenFang's shared-memory tools (memory_store / memory_recall), ported from
# RightNow-AI/openfang crates/openfang-runtime/src/tool_runner.rs — tool
# names, descriptions, parameter schemas, and result strings are verbatim.
# The kernel's shared memory becomes a flock-guarded JSON file, so the
# openfang semantics ("accessible by all agents") hold across agents in one
# process and across processes sharing a working directory.
#
# Override the store location with OPENFANG_MEMORY_PATH (default:
# tmp/openfang_memory.json under the current working directory).

require "bundler/setup"
require "brute"

require "fileutils"
require "json"

module OpenFang
  module Tools
    # File-backed stand-in for the openfang kernel's shared memory.
    module Memory
      def self.path
        ENV.fetch("OPENFANG_MEMORY_PATH") { File.join(Dir.pwd, "tmp", "openfang_memory.json") }
      end

      def self.write(key, value)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::RDWR | File::CREAT) do |f|
          f.flock(File::LOCK_EX)
          data = parse(f.read)
          data[key] = value
          f.rewind
          f.write(JSON.pretty_generate(data))
          f.flush
          f.truncate(f.pos)
        end
      end

      def self.read(key)
        return nil unless File.exist?(path)

        File.open(path, File::RDONLY) do |f|
          f.flock(File::LOCK_SH)
          parse(f.read)[key]
        end
      end

      def self.parse(raw)
        data = JSON.parse(raw)
        data.is_a?(Hash) ? data : {}
      rescue JSON::ParserError
        {}
      end
    end

    class MemoryStore < RubyLLM::Tool
      description "Store a value in shared memory accessible by all agents. Use for cross-agent coordination and data sharing."

      param :key, type: 'string', desc: "The storage key", required: true
      param :value, type: 'string', desc: "The value to store (JSON-encode objects/arrays, or pass a plain string)", required: true

      def name; "memory_store"; end

      def execute(key:, value:)
        Memory.write(key, value)
        "Stored value under key '#{key}'."
      end
    end

    class MemoryRecall < RubyLLM::Tool
      description "Recall a value from shared memory by key."

      param :key, type: 'string', desc: "The storage key to recall", required: true

      def name; "memory_recall"; end

      def execute(key:)
        value = Memory.read(key)
        return "No value found for key '#{key}'." if value.nil?

        # openfang stores the value as a JSON string and recalls it
        # pretty-printed, so plain strings come back quoted.
        JSON.pretty_generate(value)
      end
    end
  end
end
