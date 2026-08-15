# frozen_string_literal: true

require "json"

# clarify — hermes toolset: clarify
# Port of hermes-agent `tools/clarify_tool.py:308` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_clarify_requirements
module HermesTools
  class Clarify < Brute::Tool
    description "Ask the user a question when you need clarification, feedback, or a decision before proceeding. Supports three modes:\n\n1. **Single-select multiple choice** — provide up to 4 choices. The user picks one or types their own answer via a 5th 'Other' option. List the choice you recommend FIRST: the UI labels it '(Recommended)' and highlights it by default.\n2. **Multi-select multiple choice** — set multi_select=true. The user can select multiple options via checkboxes. user_response will be a list of selected choices.\n3. **Open-ended** — omit choices entirely. The user types a free-form response.\n\nCRITICAL: when you are offering options, put each option ONLY in the `choices` array — NEVER enumerate the options inside the `question` text. The UI renders `choices` as selectable rows; options written into the question string render as dead prose the user can't pick. Right: question='Which deployment target?', choices=['staging', 'prod']. Wrong: question='Which target? 1) staging 2) prod', choices=[].\n\nUse this tool when:\n- The task is ambiguous and you need the user to choose an approach\n- You want post-task feedback ('How did that work out?')\n- You want to offer to save a skill or update memory\n- A decision has meaningful trade-offs the user should weigh in on\n\nDo NOT use this tool for simple yes/no confirmation of dangerous commands (the terminal tool handles that). Prefer making a reasonable default choice yourself when the decision is low-stakes."
    params({ "type" => "object", "properties" => { "question" => { "type" => "string", "description" => "The question itself, and ONLY the question (e.g. 'Which deployment target?'). Do NOT embed the answer options here — pass them as separate elements in `choices`." }, "choices" => { "type" => "array", "items" => { "type" => "string" }, "maxItems" => 4, "description" => "REQUIRED whenever you are presenting selectable options: each distinct option is its own array element (up to 4). ORDER MATTERS: put the option you actually recommend FIRST — the UI labels it '(Recommended)' and pre-selects it, so a list ordered arbitrarily recommends the wrong thing to the user. Do not write '(Recommended)' yourself. The UI renders these as pickable rows and auto-appends an 'Other (type your answer)' option. Omit this parameter entirely ONLY for a genuinely open-ended free-text question." }, "multi_select" => { "type" => "boolean", "description" => "When true, the user can select MULTIPLE options (like checkboxes). The user_response will be a list of selected choices. When false (default), single selection (radio). Has no effect when choices is omitted (open-ended question)." } }, "required" => ["question"] })
    def name = "clarify"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "clarify")
    end
  end
end
