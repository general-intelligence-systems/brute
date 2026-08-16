# frozen_string_literal: true

require "json"

module HermesTools
  # clarify — ask the user a question mid-loop. Port of hermes-agent
  # tools/clarify_tool.py: choices ≤4, first auto-labeled "(Recommended)",
  # multi_select returns a list. The prompter (injected by the Clarify
  # middleware) blocks for the answer; timeout/unattended contexts return
  # sentinel strings instead of blocking.
  class Clarify < Brute::Tool
    description "Ask the user a clarifying question mid-task, with up to 4 choices."
    params({
      "type" => "object",
      "properties" => {
        "question" => { "type" => "string" },
        "choices" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Up to 4 choices; the first is marked recommended." },
        "multi_select" => { "type" => "boolean", "default" => false },
      },
      "required" => ["question"],
    })

    # prompter: ->(question, choices, multi_select) { String | Array<String> | nil }
    #   nil = no answer (timeout/undeliverable) → sentinel result.
    def initialize(prompter: nil, unavailable_reason: nil)
      @prompter = prompter
      @unavailable_reason = unavailable_reason
    end

    def name = "clarify"

    def execute(question:, choices: nil, multi_select: false, **_rest)
      return err("question is required") if question.to_s.strip.empty?
      return err(@unavailable_reason) if @unavailable_reason

      choices = Array(choices).first(4)
      offered = choices.dup
      offered[0] = "#{choices.first} (Recommended)" if choices.any?

      answer = @prompter.call(question, offered, multi_select)
      if answer.nil?
        return JSON.dump("question" => question, "choices_offered" => offered,
                         "user_response" => "[user did not respond — proceed with your best judgment]")
      end

      JSON.dump("question" => question, "choices_offered" => offered, "user_response" => answer)
    end

    private

    def err(message)
      JSON.dump("success" => false, "error" => message)
    end
  end
end
