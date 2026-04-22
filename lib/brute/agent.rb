# frozen_string_literal: true

module Brute
  class Agent
    attr_reader :provider, :model, :tools, :system_prompt

    def initialize(provider:, model:, tools: Brute::Tools::ALL, system_prompt: nil)
      @provider = provider
      @model = model
      @tools = tools
      @system_prompt = system_prompt
    end
  end
end
