# frozen_string_literal: true

module LLM
  ##
  # OpenAI-compatible provider for the OpenCode Go API gateway.
  #
  # OpenCode Go is the low-cost subscription plan with a restricted
  # (lite) model list. Same gateway as Zen, different endpoint path.
  #
  # @example
  #   llm = LLM::OpencodeGo.new(key: ENV["OPENCODE_API_KEY"])
  #   ctx = LLM::Context.new(llm)
  #   ctx.talk "Hello from brute"
  #
  class OpencodeGo < OpencodeZen
    ##
    # @return [Symbol]
    def name
      :opencode_go
    end

    ##
    # Returns models from the models.dev catalog.
    # Note: The Go gateway only accepts lite-tier models, but models.dev
    # doesn't distinguish between Zen and Go tiers. We show the full
    # catalog; the gateway returns an error for unsupported models.
    # @return [Brute::Providers::ModelsDev]
    def models
      Brute::Providers::ModelsDev.new(provider: self, provider_id: "opencode")
    end

    private

    def completions_path
      "/zen/go/v1/chat/completions"
    end
  end
end
