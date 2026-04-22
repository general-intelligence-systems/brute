require_relative 'providers/shell_response'
require_relative 'providers/shell'
require_relative 'providers/models_dev'
require_relative 'providers/opencode_zen'
require_relative 'providers/opencode_go'
require_relative 'providers/ollama'

module Brute
  module Providers
    ALL = {
      'anthropic' => ->(key) { LLM.anthropic(key: key).tap { Patches::AnthropicToolRole.apply! } },
      'openai' => ->(key) { LLM.openai(key: key) },
      'google' => ->(key) { LLM.google(key: key) },
      'deepseek' => ->(key) { LLM.deepseek(key: key) },
      'ollama' => ->(_key) { Providers::Ollama.new },
      'xai' => ->(key) { LLM.xai(key: key) },
      'opencode_zen' => ->(key) { LLM::OpencodeZen.new(key: key) },
      'opencode_go' => ->(key) { LLM::OpencodeGo.new(key: key) },
      'shell' => ->(_key) { Providers::Shell.new },
    }.freeze

    # Resolve the LLM provider from environment variables.
    #
    # Checks in order:
    #   1. LLM_API_KEY + LLM_PROVIDER (explicit)
    #   2. OPENCODE_API_KEY (implicit: provider = opencode_zen)
    #   3. ANTHROPIC_API_KEY (implicit: provider = anthropic)
    #   4. OPENAI_API_KEY   (implicit: provider = openai)
    #   5. GOOGLE_API_KEY   (implicit: provider = google)
    #   6. OLLAMA_HOST      (implicit: provider = ollama, local inference)
    #
    # Returns nil if no key is found. Error is deferred to Orchestrator#run.
    def self.guess_from_env
      if ENV['LLM_API_KEY']
        key = ENV['LLM_API_KEY']
        name = ENV.fetch('LLM_PROVIDER', 'opencode_zen').downcase
      elsif ENV['OPENCODE_API_KEY']
        key = ENV['OPENCODE_API_KEY']
        name = 'opencode_zen'
      elsif ENV['ANTHROPIC_API_KEY']
        key = ENV['ANTHROPIC_API_KEY']
        name = 'anthropic'
      elsif ENV['OPENAI_API_KEY']
        key = ENV['OPENAI_API_KEY']
        name = 'openai'
      elsif ENV['GOOGLE_API_KEY']
        key = ENV['GOOGLE_API_KEY']
        name = 'google'
      elsif ENV['OLLAMA_HOST']
        key = 'none'
        name = 'ollama'
      else
        return nil
      end

      factory = Providers::ALL[name]
      raise "Unknown LLM provider: #{name}. Available: #{Providers::ALL.keys.join(', ')}" unless factory

      factory.call(key)
    end
  end
end
