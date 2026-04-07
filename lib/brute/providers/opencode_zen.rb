# frozen_string_literal: true

# Ensure the OpenAI provider is loaded (llm.rb lazy-loads providers).
unless defined?(LLM::OpenAI)
  require "llm/providers/openai"
end

module LLM
  ##
  # OpenAI-compatible provider for the OpenCode Zen API gateway.
  #
  # OpenCode Zen is a curated model gateway at opencode.ai that proxies
  # requests to upstream LLM providers (Anthropic, OpenAI, Google, etc.).
  # All models are accessed via the OpenAI-compatible chat completions
  # endpoint; the gateway handles format conversion internally.
  #
  # @example
  #   llm = LLM::OpencodeZen.new(key: ENV["OPENCODE_API_KEY"])
  #   ctx = LLM::Context.new(llm)
  #   ctx.talk "Hello from brute"
  #
  # @example Anonymous access (free models only)
  #   llm = LLM::OpencodeZen.new(key: "public")
  #   ctx = LLM::Context.new(llm)
  #   ctx.talk "Hello"
  #
  class OpencodeZen < OpenAI
    HOST = "opencode.ai"

    ##
    # @param key [String] OpenCode API key, or "public" for anonymous access
    # @param (see LLM::Provider#initialize)
    def initialize(key: "public", **)
      super(host: HOST, key: key, **)
    end

    ##
    # @return [Symbol]
    def name
      :opencode_zen
    end

    ##
    # Returns the default model (Claude Sonnet 4, the most common Zen model).
    # @return [String]
    def default_model
      "claude-sonnet-4-20250514"
    end

    ##
    # Returns models from the models.dev catalog for the opencode provider.
    # @return [Brute::Providers::ModelsDev]
    def models
      Brute::Providers::ModelsDev.new(provider: self, provider_id: "opencode")
    end

    # -- Unsupported sub-APIs --

    def responses    = raise(NotImplementedError, "Use chat completions via the Zen gateway")
    def images       = raise(NotImplementedError, "Not supported via Zen gateway")
    def audio        = raise(NotImplementedError, "Not supported via Zen gateway")
    def files        = raise(NotImplementedError, "Not supported via Zen gateway")
    def moderations  = raise(NotImplementedError, "Not supported via Zen gateway")
    def vector_stores = raise(NotImplementedError, "Not supported via Zen gateway")

    private

    def completions_path
      "/zen/v1/chat/completions"
    end

    def headers
      lock do
        (@headers || {}).merge(
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{@key}",
          "x-opencode-client" => "brute"
        )
      end
    end
  end
end
