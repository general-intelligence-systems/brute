# frozen_string_literal: true

module Brute
  module Prompts
    TEXT_DIR = File.expand_path("text", __dir__)

    # Resolve a provider-specific text file.
    # Looks for +section/provider_name.txt+, falls back to +section/default.txt+.
    def self.read(section, provider_name)
      provider = provider_name.to_s
      path = File.join(TEXT_DIR, section, "#{provider}.txt")
      path = File.join(TEXT_DIR, section, "default.txt") unless File.exist?(path)
      return nil unless File.exist?(path)
      File.read(path)
    end

    # Read a named agent prompt (e.g. "explore", "compaction").
    def self.agent_prompt(name)
      path = File.join(TEXT_DIR, "agents", "#{name}.txt")
      File.exist?(path) ? File.read(path) : nil
    end
  end
end
