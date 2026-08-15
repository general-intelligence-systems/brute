# frozen_string_literal: true

require "json"

# computer_use — hermes toolset: computer_use
# Port of hermes-agent `tools/computer_use_tool.py:20` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_computer_use_requirements
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: COMPUTER_USE_SCHEMA
module HermesTools
  class ComputerUse < Brute::Tool
    description "Universal desktop control via cua-driver (macOS, Windows, Linux). Works with any tool-capable model (Anthropic, OpenAI, OpenRouter, local vLLM, etc.). Background computer-use: does NOT steal the user's cursor or keyboard focus."
    params({ "type" => "object", "properties" => {} })
    def name = "computer_use"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "computer_use")
    end
  end
end
