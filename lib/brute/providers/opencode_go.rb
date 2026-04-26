# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Providers
    ##
    # OpenAI-compatible provider for the OpenCode Go API gateway.
    #
    # OpenCode Go is the low-cost subscription plan with a restricted
    # (lite) model list. Same gateway as Zen, different endpoint path.
    #
    class OpencodeGo < OpencodeZen
      def name
        :opencode_go
      end

      ##
      # Returns models from the models.dev catalog.
      # Note: The Go gateway only accepts lite-tier models, but models.dev
      # doesn't distinguish between Zen and Go tiers. We show the full
      # catalog; the gateway returns an error for unsupported models.
      def models
        ModelsDev.new(provider: self, provider_id: "opencode")
      end

      def ruby_llm_provider
        @ruby_llm_provider ||= begin
          config = RubyLLM::Configuration.new
          config.openai_api_key = @key
          config.openai_api_base = "https://#{HOST}/zen/go/v1"
          RubyLLM::Providers::OpenAI.new(config)
        end
      end
    end
  end
end
