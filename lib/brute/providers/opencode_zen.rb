# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Providers
    ##
    # OpenAI-compatible provider for the OpenCode Zen API gateway.
    #
    # OpenCode Zen is a curated model gateway at opencode.ai that proxies
    # requests to upstream LLM providers (Anthropic, OpenAI, Google, etc.).
    # All models are accessed via the OpenAI-compatible chat completions
    # endpoint; the gateway handles format conversion internally.
    #
    # @example
    #   provider = Brute::Providers::OpencodeZen.new(key: ENV["OPENCODE_API_KEY"])
    #   provider.ruby_llm_provider.complete(messages, ...)
    #
    class OpencodeZen
      HOST = "opencode.ai"

      attr_reader :key

      ##
      # @param key [String] OpenCode API key, or "public" for anonymous access
      def initialize(key: "public")
        @key = key
      end

      def name
        :opencode_zen
      end

      def default_model
        "zen-bickpickle"
      end

      ##
      # Returns models from the models.dev catalog for the opencode provider.
      def models
        ModelsDev.new(provider: self, provider_id: "opencode")
      end

      ##
      # Extra headers to pass through on every LLM call.
      def extra_headers
        { "x-opencode-client" => "brute" }
      end

      ##
      # Returns a RubyLLM::Providers::OpenAI instance pointed at the Zen gateway.
      def ruby_llm_provider
        @ruby_llm_provider ||= begin
          config = RubyLLM::Configuration.new
          config.openai_api_key = @key
          config.openai_api_base = "https://#{HOST}/zen/v1"
          RubyLLM::Providers::OpenAI.new(config)
        end
      end
    end
  end
end
