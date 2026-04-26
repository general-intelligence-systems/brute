require 'brute/providers/shell_response'
require 'brute/providers/shell'
require 'brute/providers/models_dev'
require 'brute/providers/opencode_zen'
require 'brute/providers/opencode_go'
require 'brute/providers/ollama'

module Brute
  module Providers
    # Simple wrapper for providers that just need a key + ruby_llm provider class.
    class Simple
      attr_reader :key

      def initialize(key:, provider_class:, config_key:, name:, default_model:)
        @key = key
        @provider_class = provider_class
        @config_key = config_key
        @name_sym = name
        @default_model_id = default_model
      end

      def name;          @name_sym; end
      def default_model; @default_model_id; end

      def ruby_llm_provider
        @ruby_llm_provider ||= begin
          config = RubyLLM::Configuration.new
          config.send(:"#{@config_key}=", @key)
          @provider_class.new(config)
        end
      end
    end

    ALL = {
      'anthropic' => ->(key) {
        Simple.new(key: key, provider_class: RubyLLM::Providers::Anthropic,
                   config_key: :anthropic_api_key, name: :anthropic,
                   default_model: "claude-sonnet-4-20250514")
      },
      'openai' => ->(key) {
        Simple.new(key: key, provider_class: RubyLLM::Providers::OpenAI,
                   config_key: :openai_api_key, name: :openai,
                   default_model: "gpt-4.1")
      },
      'google' => ->(key) {
        Simple.new(key: key, provider_class: RubyLLM::Providers::Gemini,
                   config_key: :gemini_api_key, name: :google,
                   default_model: "gemini-2.5-pro")
      },
      'deepseek' => ->(key) {
        Simple.new(key: key, provider_class: RubyLLM::Providers::DeepSeek,
                   config_key: :deepseek_api_key, name: :deepseek,
                   default_model: "deepseek-chat")
      },
      'ollama' => ->(_key) { Providers::Ollama.new },
      'xai' => ->(key) {
        Simple.new(key: key, provider_class: RubyLLM::Providers::XAI,
                   config_key: :xai_api_key, name: :xai,
                   default_model: "grok-3")
      },
      'opencode_zen' => ->(key) { Providers::OpencodeZen.new(key: key) },
      'opencode_go'  => ->(key) { Providers::OpencodeGo.new(key: key) },
      'shell'        => ->(_key) { Providers::Shell.new },
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
    # Returns nil if no key is found. Error is deferred to the caller.
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
