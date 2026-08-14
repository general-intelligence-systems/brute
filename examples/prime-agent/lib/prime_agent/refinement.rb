# frozen_string_literal: true

require "json"
require "time"

require_relative "harness_store"

module PrimeAgent
  # The /refine machinery — a Ruby port of prime-agent's refinement engine
  # (packages/coding-agent/src/core/refinement/refinement.ts), adapted for
  # the IRuby kernel:
  #
  #  - skill references are `{"type" => "ruby", "import" => ..., "callable"
  #    or "call_pattern" => ...}` (the kernel is Ruby, not Python);
  #  - the subagent guidance keeps no `rlm(...)` spawn form (not wired in
  #    this port) — subagent entries are reusable delegation specs;
  #  - the LLM is injected as a callable so specs need no network.
  #
  # Everything except Engine is a pure function — the orchestration (turn
  # counting, request file, history) lives in refiner.rb.
  module Refinement
    TRUNCATED_JSON_ERROR =
      "the model stopped before completing its JSON object. This usually means " \
      "the output budget was exhausted; retry with a smaller request."
    MAX_OUTPUT_TOKENS = 32_000
    REVIEW_MAX_OUTPUT_TOKENS = 4_096
    TOOL_RESULT_MAX_CHARS = 2_000
    CONVERSATION_MAX_CHARS = 80_000
    REVIEW_CONVERSATION_MAX_CHARS = 40_000
    OVERVIEW_ENTRY_LIMIT = 40
    OVERVIEW_CONTENT_LIMIT = 240
    HISTORY_LIMIT = 20

    class ParseError < StandardError; end

    # Adapted from REFINEMENT_SYSTEM_PROMPT (refinement.ts:123-173).
    REFINEMENT_SYSTEM_PROMPT = <<~TXT
      You are the /refine continual harness subsystem of this agent (a brute/Ruby port of Prime Agent).

      Your job is to improve the editable continual harness state from the current trajectory.
      This is similar in spirit to context compaction, but instead of summarizing the
      conversation you emit precise Create, Update, or Delete edits to reusable state.
      The continual harness is the persistent, editable set of prompt notes, memories,
      skills, and subagent specs that lets the agent improve reusable behavior
      outside the token history.
      Use "continual harness" for that persistent artifact layer; keep "kernel runtime" for the
      IRuby kernel and native call interface that executes those artifacts.

      Continual harness components:
      - prompt: supplemental prompt notes only. The base system prompt is immutable and MUST NOT be rewritten.
      - memory: durable facts, decisions, failures, preferences, and outcomes.
      - skill: Ruby REPL skill. Skill create/update edits MUST include a `reference` object with `{"type":"ruby"}`, a Ruby require-able `import` (or a file path to `load`), and a `callable` or `call_pattern`; they also MUST include an `arguments` object describing accepted inputs, required fields, defaults, and constraints. Use `{}` for `arguments` only when the Ruby callable truly needs no external inputs. Include the native call form `require "<import>"; <callable>(...)`.
      - subagent: reusable delegation specs, including purpose, instructions, and when to invoke. Include the native call form: compose a concise task prompt and spawn with `KernelAgent.spawn("<task>")`; admission returns a handle immediately, never the child's answer. Results arrive via `KernelAgent.finished` on a later turn or via files. Do not invent wrappers like `run_subagent(...)`.

      Scope and persistence policy:
      - The default editable continual harness store is local to the current session. Use it for session-specific progress, active task state, current-run coordination notes, temporary blockers, and project facts that should not affect other sessions.
      - A caller may explicitly request global refinement. Global edits must be stable cross-session lessons, durable user preferences, reusable skills/subagents, or tool/environment facts that should affect future sessions.
      - Entry ids in the harness overview may carry a display-only `local:` or `global:` prefix. Always use the bare id (no prefix) in edits.
      - All edits in one refinement apply only to the requested scope's store. During a local refinement, global entries are read-only context: never propose update or delete edits for them; create a local entry instead when a session-specific override is genuinely needed.
      - Project/workspace-specific lessons may be persisted globally only when the title, path, or content explicitly names the project/workspace and the lesson is likely to be reused in future sessions for that project. Prefer local edits when the lesson only belongs in the current conversation.
      - Use memory for declarative facts and preferences, skill for repeatable procedures exposed as Ruby calls, prompt for narrow behavioral policy addendums, and subagent for reusable delegation roles.
      - Create or update the smallest relevant component: repeated delegation roles should become subagent specs, repeated procedures should become skills, durable facts/preferences should become memories, and narrow behavioral policies should become prompt addendums.
      - When an edit is persisted, include metadata such as `{"scope":"local"}` or `{"scope":"global"}` when that helps future review understand the intended blast radius.

      Use the trajectory, current continual harness state, and prior refinement history. Prefer
      small evidence-backed edits. If prior refinements caused issues, rollback or
      replace the faulty editable entries. Never edit source files directly. Output
      JSON only with this exact shape:

      {
        "summary": "one sentence",
        "rationale": "why these edits are justified by trajectory evidence",
        "expectedOutcome": "what should improve and how to validate it",
        "edits": [
          {
            "action": "create|update|delete",
            "kind": "prompt|memory|skill|subagent",
            "id": "stable id for update/delete, optional for create",
            "title": "required for create/update except delete",
            "content": "required for create/update except delete",
            "path": "optional grouping path",
            "reference": {"type": "ruby", "import": "some_feature", "callable": "SomeModule.call", "call_pattern": "SomeModule.call(x)"},
            "arguments": {"name": {"type": "string", "required": true, "description": "accepted input"}},
            "metadata": {},
            "reason": "why this edit is useful"
          }
        ]
      }
    TXT

    # Verbatim port of AUTO_REFINE_REVIEW_SYSTEM_PROMPT (refinement.ts:175-185).
    AUTO_REFINE_REVIEW_SYSTEM_PROMPT = <<~TXT
      You are Prime Agent's automatic /refine review gate.

      Decide whether this checkpoint should run /refine. Auto /refine writes local continual harness state by default, so approve when the trajectory contains evidence useful to this session's future turns.
      Reject one-off noise, unsupported hypotheses, and transient tool outputs. Ask for global refinement only for durable cross-session lessons or explicitly project-qualified lessons likely to be reused in future sessions.

      Return JSON only:
      {
        "shouldRefine": true|false,
        "rationale": "short reason",
        "instructions": "optional concise instructions for /refine if shouldRefine is true"
      }
    TXT

    LOCAL_SCOPE_INSTRUCTION = <<~TXT.strip.freeze
      Requested refinement scope: local. Prefer local continual harness edits for current task progress, temporary blockers, current-run coordination, and project facts that are not clearly reusable across Prime Agent sessions. Global entries in the overview are read-only context: do not propose update or delete edits for them; create a local entry instead if an override is needed.
    TXT

    GLOBAL_SCOPE_INSTRUCTION = <<~TXT.strip.freeze
      Requested refinement scope: global. Only propose stable cross-session continual harness edits, durable user preferences, reusable skills/subagents, or explicitly project-qualified facts that should affect future Prime Agent sessions. Do not persist session-only progress, temporary blockers, or current-run coordination globally.
    TXT

    module_function

    # ------------------------------------------------------------------
    # Response parsing (refinement.ts:564-662)
    # ------------------------------------------------------------------

    def extract_json_object(text)
      trimmed = text.to_s.strip
      return parse_json_candidate(trimmed) if trimmed.start_with?("{") && trimmed.end_with?("}")

      fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/)
      return parse_json_candidate(fenced[1].strip) if fenced

      start = trimmed.index("{")
      finish = trimmed.rindex("}")
      if start && finish && finish > start
        begin
          return JSON.parse(trimmed[start..finish])
        rescue JSON::ParserError
          return parse_json_candidate(trimmed[start..])
        end
      end
      raise ParseError, TRUNCATED_JSON_ERROR if incomplete_json?(trimmed)

      raise ParseError, "Refiner did not return a JSON object"
    end

    # A candidate ends mid-value when a string is unterminated or
    # objects/arrays are unclosed — the signature of an exhausted output
    # budget, distinct from complete-but-malformed JSON.
    def incomplete_json?(candidate)
      depth = 0
      in_string = false
      escaped = false
      candidate.each_char do |char|
        if escaped
          escaped = false
          next
        end
        if in_string
          if char == "\\"
            escaped = true
          elsif char == '"'
            in_string = false
          end
          next
        end
        if char == '"'
          in_string = true
        elsif char == "{" || char == "["
          depth += 1
        elsif char == "}" || char == "]"
          depth -= 1
        end
      end
      in_string || depth.positive?
    end

    def parse_json_candidate(candidate)
      JSON.parse(candidate)
    rescue JSON::ParserError => error
      raise ParseError, TRUNCATED_JSON_ERROR if incomplete_json?(candidate)

      raise ParseError, "the model did not return valid JSON: #{error.message}"
    end

    def parse_proposal(text)
      value = extract_json_object(text)
      raise ParseError, "Refiner JSON must be an object" unless value.is_a?(Hash)

      edits = value["edits"].is_a?(Array) ? value["edits"] : []
      {
        summary: value["summary"].is_a?(String) ? value["summary"] : "Refined continual harness state",
        rationale: value["rationale"].is_a?(String) ? value["rationale"] : "",
        expected_outcome: value["expectedOutcome"].is_a?(String) ? value["expectedOutcome"] : "",
        edits: edits.select { |edit| edit.is_a?(Hash) }.map { |edit| normalize_edit(edit) },
      }
    end

    def parse_review(text)
      value = extract_json_object(text)
      raise ParseError, "Auto-refine review JSON must be an object" unless value.is_a?(Hash)

      {
        should_refine: value["shouldRefine"] == true,
        rationale: value["rationale"].is_a?(String) ? value["rationale"] : "No rationale provided.",
        instructions: value["instructions"].is_a?(String) ? value["instructions"] : nil,
      }
    end

    def normalize_edit(edit)
      {
        action: edit["action"],
        kind: edit["kind"],
        id: edit["id"].is_a?(String) ? edit["id"] : nil,
        title: edit["title"].is_a?(String) ? edit["title"] : nil,
        content: edit["content"].is_a?(String) ? edit["content"] : nil,
        path: edit["path"].is_a?(String) ? edit["path"] : nil,
        reference: edit["reference"].is_a?(Hash) ? edit["reference"] : nil,
        arguments: edit["arguments"].is_a?(Hash) ? edit["arguments"] : nil,
        metadata: edit["metadata"].is_a?(Hash) ? edit["metadata"] : nil,
        reason: edit["reason"].is_a?(String) ? edit["reason"] : nil,
      }
    end

    # ------------------------------------------------------------------
    # Validation + apply (refinement.ts:664-802)
    # ------------------------------------------------------------------

    def validate_edit(edit, computed_id = nil)
      return "unsupported action #{edit[:action]}" unless %w[create update delete].include?(edit[:action])
      return "unsupported kind #{edit[:kind]}" unless HarnessStore::KINDS.include?(edit[:kind])

      if edit[:kind] == "prompt" && (edit[:id] == "base_system_prompt" || computed_id == "base_system_prompt")
        return "base system prompt is not editable"
      end
      return "#{edit[:action]} requires id" if edit[:action] != "create" && !edit[:id]

      if edit[:action] != "delete" && (!edit[:title] || !edit[:content])
        return "#{edit[:action]} requires title and content"
      end
      if edit[:action] != "delete" && edit[:kind] == "skill"
        return "#{edit[:action]} skill requires arguments" if edit[:arguments].nil?

        reference = edit[:reference]
        return "#{edit[:action]} skill requires ruby reference" if reference.nil?
        return "#{edit[:action]} skill reference.type must be ruby" unless reference["type"] == "ruby"

        has_import = %w[import require].any? { |key| reference[key].is_a?(String) && !reference[key].empty? }
        has_callable = %w[callable call_pattern].any? { |key| reference[key].is_a?(String) && !reference[key].empty? }
        return "#{edit[:action]} skill requires a ruby import" unless has_import
        return "#{edit[:action]} skill requires callable or call_pattern" unless has_callable
      end
      nil
    end

    # Applies a proposal to one store, per-edit recording before/after
    # snapshots. When `baseline` is given (the target store's state captured
    # before planning), an entry that changed since planning rejects the
    # edit — the kernel may have written the shared file while the LLM
    # planned.
    def apply_proposal(store, proposal, id:, rollback_of: nil, baseline: nil)
      applied_edits = []
      modified_keys = {}
      proposal[:edits].each do |edit|
        computed_id = edit[:id] ||
                      (edit[:action] == "create" ? HarnessStore.slug(edit[:title] || edit[:kind], edit[:kind]) : nil)
        entry_id = computed_id.to_s
        if (validation_error = validate_edit(edit, computed_id))
          applied_edits << edit.merge(id: entry_id, applied: false, error: validation_error)
          next
        end

        key = "#{edit[:kind]}:#{entry_id}"
        before = store.get(edit[:kind], entry_id)
        if baseline && !modified_keys[key]
          baseline_entry = baseline.dig("entries", edit[:kind], entry_id)
          unless canonical_json(before) == canonical_json(baseline_entry)
            applied_edits << edit.merge(id: entry_id, applied: false,
                                        error: "entry changed during refinement planning")
            next
          end
        end

        case edit[:action]
        when "delete"
          if before.nil?
            applied_edits << edit.merge(id: entry_id, applied: false, error: "entry not found")
            next
          end
          store.delete(edit[:kind], entry_id)
          applied_edits << edit.merge(id: entry_id, applied: true, before: before)
        when "create"
          if before
            applied_edits << edit.merge(id: entry_id, applied: false, error: "entry already exists")
            next
          end
          after = build_entry(store, edit, entry_id, before)
          store.write_entry(after)
          applied_edits << edit.merge(id: entry_id, applied: true, after: after)
        when "update"
          if before.nil?
            applied_edits << edit.merge(id: entry_id, applied: false, error: "entry not found")
            next
          end
          after = build_entry(store, edit, entry_id, before)
          store.write_entry(after)
          applied_edits << edit.merge(id: entry_id, applied: true, before: before, after: after)
        end
        modified_keys[key] = true
      end

      changes = applied_edits.select { |edit| edit[:applied] }
                             .map { |edit| "#{edit[:action]} #{edit[:kind]}:#{edit[:id]}" }
      store.record_refinement(proposal[:summary], changes,
                              evidence: proposal[:rationale],
                              outcome: proposal[:expected_outcome],
                              id: id)
      {
        id: id,
        summary: proposal[:summary],
        rationale: proposal[:rationale],
        expected_outcome: proposal[:expected_outcome],
        applied_edits: applied_edits,
        harness_state_path: store.file_path,
        rollback_of: rollback_of,
        scope: store.scope,
      }
    end

    def build_entry(store, edit, entry_id, before)
      now = HarnessStore.now
      {
        "id" => entry_id,
        "kind" => edit[:kind],
        "title" => edit[:title] || (before && before["title"]) || entry_id,
        "content" => edit[:content] || (before && before["content"]) || "",
        "path" => edit[:path] || (before && before["path"]) || "general",
        "scope" => (before && before["scope"]) || store.scope,
        "reference" => edit[:reference] || (before && before["reference"]) || {},
        "arguments" => edit[:arguments] || (before && before["arguments"]) || {},
        "metadata" => edit[:metadata] || (before && before["metadata"]) || {},
        "source" => "refine",
        "created_at" => (before && before["created_at"]) || now,
        "updated_at" => now,
        "version" => before ? before["version"].to_i + 1 : 1,
      }
    end

    # A rollback proposal for a previously applied refinement: edits replay
    # in reverse, creates become deletes, deletes become creates, updates
    # restore the before-snapshot (refinement.ts:804-836).
    def rollback_proposal(result)
      edits = result[:applied_edits].reverse.filter_map do |edit|
        next unless edit[:applied]

        before = edit[:before]
        after = edit[:after]
        if before
          {
            action: after ? "update" : "create",
            kind: edit[:kind],
            id: edit[:id],
            title: before["title"],
            content: before["content"],
            path: before["path"],
            reference: before["reference"],
            arguments: before["arguments"],
            metadata: before["metadata"],
            reason: "Rollback #{result[:id]}",
          }
        elsif after
          { action: "delete", kind: edit[:kind], id: edit[:id], reason: "Rollback #{result[:id]}" }
        end
      end
      {
        summary: "Rollback refinement #{result[:id]}",
        rationale: "Rollback #{result[:id]}",
        expected_outcome: "",
        edits: edits,
      }
    end

    # Key-order-independent comparison for the baseline check.
    def canonical_json(object)
      JSON.generate(deep_sort(object))
    end

    def deep_sort(object)
      case object
      when Hash
        object.keys.sort.each_with_object({}) { |key, sorted| sorted[key] = deep_sort(object[key]) }
      when Array
        object.map { |value| deep_sort(value) }
      else
        object
      end
    end

    # ------------------------------------------------------------------
    # Prompt-side formatting (refinement.ts overviewForPrompt /
    # historyForPrompt + compaction/utils.ts serializeConversation)
    # ------------------------------------------------------------------

    def overview_for_prompt(state)
      lines = []
      HarnessStore::KINDS.each do |kind|
        entries = state["entries"][kind].values
        lines << "#{kind}: #{entries.length}"
        entries.first(OVERVIEW_ENTRY_LIMIT).each do |entry|
          lines << "- #{overview_entry_line(entry)}"
        end
        overflow = entries.length - OVERVIEW_ENTRY_LIMIT
        lines << "- +#{overflow} more #{kind} entries" if overflow.positive?
      end
      lines.join("\n")
    end

    def overview_entry_line(entry)
      content = entry["content"].to_s.gsub(/\s+/, " ")[0, OVERVIEW_CONTENT_LIMIT]
      reference_text = ""
      arguments_text = ""
      if entry["kind"] == "skill"
        reference = entry["reference"].to_h
        arguments = entry["arguments"].to_h
        reference_text = " ref=#{JSON.generate(reference)[0, OVERVIEW_CONTENT_LIMIT]}" unless reference.empty?
        arguments_text = " args=#{JSON.generate(arguments)[0, OVERVIEW_CONTENT_LIMIT]}" unless arguments.empty?
      end
      "[#{entry["scope"] || "global"}:#{entry["id"]}] #{entry["title"]} " \
        "(#{entry["path"]}, v#{entry["version"]})#{reference_text}#{arguments_text}: #{content}"
    end

    def history_for_prompt(history)
      return "No prior refinement history." if history.empty?

      history.last(HISTORY_LIMIT).map do |item|
        edits = item[:applied_edits]
                .map { |edit| "#{edit[:applied] ? "applied" : "failed"} #{edit[:action]} #{edit[:kind]}:#{edit[:id]}" }
                .join(", ")
        rollback = item[:rollback_of] ? " rollbackOf=#{item[:rollback_of]}" : ""
        "[#{item[:id]}]#{rollback} #{item[:summary]}\n#{edits}\nExpected outcome: #{item[:expected_outcome]}"
      end.join("\n\n")
    end

    def serialize_conversation(messages)
      parts = []
      messages.each do |message|
        case message.role.to_sym
        when :user
          parts << "[User]: #{message.content}" if present?(message.content)
        when :assistant
          parts << "[Assistant]: #{message.content}" if present?(message.content)
          next unless message.tool_call?

          calls = message.tool_calls.map do |tool_call|
            args = tool_call.arguments.map { |key, value| "#{key}=#{JSON.generate(value)}" }.join(", ")
            "#{tool_call.name}(#{args})"
          end
          parts << "[Assistant tool calls]: #{calls.join("; ")}"
        when :tool
          if present?(message.content)
            parts << "[Tool result]: #{truncate_for_summary(message.content, TOOL_RESULT_MAX_CHARS)}"
          end
        end
      end
      parts.join("\n\n")
    end

    def truncate_for_summary(text, max_chars)
      return text if text.length <= max_chars

      "#{text[0, max_chars]}\n\n[... #{text.length - max_chars} more characters truncated]"
    end

    def present?(content)
      !(content.nil? || content.to_s.empty?)
    end

    # ------------------------------------------------------------------
    # The LLM-driving half. `llm` is a callable:
    #   llm.call(system:, user:, max_tokens:) -> String
    # ------------------------------------------------------------------
    class Engine
      def initialize(llm:)
        @llm = llm
      end

      # Returns [proposal, refinement_id]. (Port of planRefinement minus
      # the rollback branch — the Refiner builds rollback proposals itself.)
      def plan(messages:, state:, history:, instructions: nil, scope: "local")
        id = self.class.new_refinement_id
        user_prompt = [
          "<current_harness_state>\n#{Refinement.overview_for_prompt(state)}\n</current_harness_state>",
          "<refinement_history>\n#{Refinement.history_for_prompt(history)}\n</refinement_history>",
          "<conversation>\n#{conversation_slice(messages, CONVERSATION_MAX_CHARS)}\n</conversation>",
          "<scope_policy>\n#{scope == "global" ? GLOBAL_SCOPE_INSTRUCTION : LOCAL_SCOPE_INSTRUCTION}\n</scope_policy>",
          instructions && "<user_refine_instructions>\n#{instructions}\n</user_refine_instructions>",
          "Return only JSON edits. If no useful edit is justified, return an empty edits array with a rationale.",
        ].compact.join("\n\n")

        text = @llm.call(system: REFINEMENT_SYSTEM_PROMPT, user: user_prompt,
                         max_tokens: MAX_OUTPUT_TOKENS)
        [Refinement.parse_proposal(text), id]
      end

      # The auto-refine review gate (port of reviewAutoRefine).
      def review(messages:, state:, history:, reason:, turns_since_last_review:)
        user_prompt = [
          "<trigger>\n#{reason}; #{turns_since_last_review} assistant turns since last auto-refine review\n</trigger>",
          "<current_harness_state>\n#{Refinement.overview_for_prompt(state)}\n</current_harness_state>",
          "<refinement_history>\n#{Refinement.history_for_prompt(history)}\n</refinement_history>",
          "<conversation>\n#{conversation_slice(messages, REVIEW_CONVERSATION_MAX_CHARS)}\n</conversation>",
          "Return shouldRefine=true when the trajectory contains evidence useful to this session's " \
            "future turns. Prefer local harness edits for current task progress, temporary blockers, " \
            "and current-run coordination. Ask for global refinement only for durable cross-session " \
            "lessons or explicitly project-qualified lessons likely to be reused in future sessions.",
        ].join("\n\n")

        text = @llm.call(system: AUTO_REFINE_REVIEW_SYSTEM_PROMPT, user: user_prompt,
                         max_tokens: REVIEW_MAX_OUTPUT_TOKENS)
        Refinement.parse_review(text)
      end

      def self.new_refinement_id
        "refine_#{Time.now.utc.iso8601(3).gsub(/[^0-9]/, "")[0, 17]}"
      end

      private

      def conversation_slice(messages, max_chars)
        text = Refinement.serialize_conversation(messages)
        text.length > max_chars ? text[-max_chars..] : text
      end
    end
  end
end

__END__

require "brute/messages"
require "tmpdir"

describe "prime_agent/refinement" do
  R = PrimeAgent::Refinement

  describe "extract_json_object" do
    it "parses a bare object" do
      R.extract_json_object(%q({"a": 1})).should == { "a" => 1 }
    end

    it "parses a fenced object" do
      R.extract_json_object("here you go:\n```json\n{\"a\": 1}\n```\nthanks").should == { "a" => 1 }
    end

    it "slices JSON out of surrounding prose" do
      R.extract_json_object(%q(sure! {"a": 1} hope that helps)).should == { "a" => 1 }
    end

    it "diagnoses truncated JSON (unterminated string / unclosed braces)" do
      lambda { R.extract_json_object(%q!{"summary": "never ends!) }.should.raise(R::ParseError)
      begin
        R.extract_json_object(%q!{"summary": "never ends!)
      rescue R::ParseError => error
        error.message.should == R::TRUNCATED_JSON_ERROR
      end
    end

    it "rejects empty/non-JSON replies" do
      lambda { R.extract_json_object("no json here") }.should.raise(R::ParseError)
    end
  end

  describe "incomplete_json?" do
    it "tracks strings, escapes, and depth" do
      R.incomplete_json?(%q({"a": "b"})).should.be.false
      R.incomplete_json?(%q({"a": "b})).should.be.true
      R.incomplete_json?(%q({"a": "esc\\"})).should.be.true  # escaped quote → still in string
      R.incomplete_json?(%q({"a": [1, 2})).should.be.true
      R.incomplete_json?(%q({"a": [1, 2]})).should.be.false
    end
  end

  describe "parse_proposal" do
    it "defaults missing fields tolerantly" do
      proposal = R.parse_proposal(%q({"edits": [{"action": "create", "kind": "memory"}]}))
      proposal[:summary].should == "Refined continual harness state"
      proposal[:rationale].should == ""
      proposal[:edits].length.should == 1
      proposal[:edits].first[:id].should.be.nil
      proposal[:edits].first[:reference].should.be.nil
    end

    it "rejects non-object JSON" do
      lambda { R.parse_proposal(%q([1, 2])) }.should.raise(R::ParseError)
    end
  end

  describe "validate_edit" do
    def edit(overrides = {})
      { action: "create", kind: "memory", id: nil, title: "T", content: "C",
        path: nil, reference: nil, arguments: nil, metadata: nil, reason: nil }.merge(overrides)
    end

    it "accepts a basic memory create" do
      R.validate_edit(edit).should.be.nil
    end

    it "rejects bad actions and kinds" do
      R.validate_edit(edit(action: "frobnicate")).should == "unsupported action frobnicate"
      R.validate_edit(edit(kind: "widget")).should == "unsupported kind widget"
    end

    it "protects the base system prompt" do
      R.validate_edit(edit(kind: "prompt", id: "base_system_prompt"))
        .should == "base system prompt is not editable"
    end

    it "requires id for update/delete and title+content for create/update" do
      R.validate_edit(edit(action: "update")).should == "update requires id"
      R.validate_edit(edit(action: "delete")).should == "delete requires id"
      R.validate_edit(edit(title: nil)).should == "create requires title and content"
    end

    it "enforces the skill reference contract (ruby type, import, callable)" do
      R.validate_edit(edit(kind: "skill")).should == "create skill requires arguments"
      R.validate_edit(edit(kind: "skill", arguments: {}))
        .should == "create skill requires ruby reference"
      R.validate_edit(edit(kind: "skill", arguments: {},
                           reference: { "type" => "python", "import" => "x", "callable" => "y" }))
        .should == "create skill reference.type must be ruby"
      R.validate_edit(edit(kind: "skill", arguments: {},
                           reference: { "type" => "ruby", "callable" => "y" }))
        .should == "create skill requires a ruby import"
      R.validate_edit(edit(kind: "skill", arguments: {},
                           reference: { "type" => "ruby", "import" => "x" }))
        .should == "create skill requires callable or call_pattern"
      R.validate_edit(edit(kind: "skill", arguments: {},
                           reference: { "type" => "ruby", "import" => "x", "call_pattern" => "X.call(a)" }))
        .should.be.nil
    end
  end

  describe "apply_proposal" do
    def with_store(&block)
      Dir.mktmpdir { |dir| block.call(PrimeAgent::HarnessStore.new(dir, scope: "local")) }
    end

    def proposal_with(edits)
      { summary: "test refine", rationale: "evidence", expected_outcome: "better", edits: edits }
    end

    it "creates, updates, and deletes entries with version bookkeeping" do
      with_store do |store|
        result = R.apply_proposal(store, proposal_with([
          { action: "create", kind: "memory", title: "Deploy command", content: "bin/deploy" },
        ]), id: "refine_test_1")
        result[:applied_edits].first[:applied].should.be.true
        entry = store.get("memory", "deploy_command")
        entry["version"].should == 1
        entry["source"].should == "refine"

        R.apply_proposal(store, proposal_with([
          { action: "update", kind: "memory", id: "deploy_command", title: "Deploy command", content: "bin/deploy --prod" },
        ]), id: "refine_test_2")
        store.get("memory", "deploy_command")["version"].should == 2
        store.get("memory", "deploy_command")["content"].should == "bin/deploy --prod"

        R.apply_proposal(store, proposal_with([
          { action: "delete", kind: "memory", id: "deploy_command" },
        ]), id: "refine_test_3")
        store.get("memory", "deploy_command").should.be.nil
        store.refinements.map { |event| event["id"] }
             .should == %w[refine_test_1 refine_test_2 refine_test_3]
      end
    end

    it "records failed edits with reasons instead of raising" do
      with_store do |store|
        result = R.apply_proposal(store, proposal_with([
          { action: "update", kind: "memory", id: "ghost", title: "T", content: "C" },
          { action: "create", kind: "memory", title: "Real", content: "C" },
          { action: "create", kind: "memory", title: "Real", content: "C2" },
        ]), id: "refine_test")
        first, second, third = result[:applied_edits]
        first[:applied].should.be.false
        first[:error].should == "entry not found"
        second[:applied].should.be.true
        third[:applied].should.be.false
        third[:error].should == "entry already exists"
        result[:applied_edits].count { |e| e[:applied] }.should == 1
        store.refinements.first["changes"].should == ["create memory:real"]
      end
    end

    it "rejects edits whose baseline entry changed during planning" do
      with_store do |store|
        store.create("memory", "Fact", "v1")
        baseline = store.state
        store.update("memory", "fact", "Fact", "v2 kernel-side write")
        result = R.apply_proposal(store, proposal_with([
          { action: "update", kind: "memory", id: "fact", title: "Fact", content: "v3 refine" },
        ]), id: "refine_test", baseline: baseline)
        result[:applied_edits].first[:applied].should.be.false
        result[:applied_edits].first[:error].should == "entry changed during refinement planning"
        store.get("memory", "fact")["content"].should == "v2 kernel-side write"
      end
    end

    it "before/after snapshots feed rollback_proposal (create→delete, delete→create, update→restore)" do
      with_store do |store|
        create_result = R.apply_proposal(store, proposal_with([
          { action: "create", kind: "memory", title: "Ephemeral", content: "x" },
        ]), id: "r1")
        rollback = R.rollback_proposal(create_result)
        rollback[:summary].should == "Rollback refinement r1"
        rollback[:edits].first[:action].should == "delete"

        store.create("memory", "Doomed", "old content", path: "p")
        delete_result = R.apply_proposal(store, proposal_with([
          { action: "delete", kind: "memory", id: "doomed" },
        ]), id: "r2")
        restore = R.rollback_proposal(delete_result)
        restore[:edits].first[:action].should == "create"
        restore[:edits].first[:content].should == "old content"
        restore[:edits].first[:path].should == "p"

        store.create("memory", "Mutable", "before")
        update_result = R.apply_proposal(store, proposal_with([
          { action: "update", kind: "memory", id: "mutable", title: "Mutable", content: "after" },
        ]), id: "r3")
        undo = R.rollback_proposal(update_result)
        undo[:edits].first[:action].should == "update"
        undo[:edits].first[:content].should == "before"
      end
    end
  end

  describe "serialize_conversation" do
    it "renders roles, tool calls and truncates tool results" do
      messages = [
        Brute::Message.new(role: :user, content: "hi"),
        Brute::Message.new(role: :assistant, content: "let me check",
                           tool_calls: [{ id: "t1", name: "iruby", arguments: { "code" => "ls" } }]),
        Brute::Message.new(role: :tool, content: "x" * 3_000, tool_call_id: "t1"),
        Brute::Message.new(role: :assistant, content: "done"),
      ]
      text = R.serialize_conversation(messages)
      text.should.include "[User]: hi"
      text.should.include "[Assistant]: let me check"
      text.should.include '[Assistant tool calls]: iruby(code="ls")'
      text.should.include "more characters truncated"
      text.should.include "[Assistant]: done"
    end
  end

  describe "overview_for_prompt / history_for_prompt" do
    it "renders kinds and entries" do
      Dir.mktmpdir do |dir|
        store = PrimeAgent::HarnessStore.new(dir, scope: "local")
        store.create("memory", "Fact", "content")
        out = R.overview_for_prompt(store.state)
        out.should.include "memory: 1"
        out.should.include "[local:fact] Fact (general, v1): content"
      end
    end

    it "renders history with applied/failed and rollbackOf" do
      history = [{
        id: "r1", summary: "s", expected_outcome: "o", rollback_of: "r0",
        applied_edits: [
          { applied: true, action: "create", kind: "memory", id: "a" },
          { applied: false, action: "delete", kind: "skill", id: "b" },
        ],
      }]
      out = R.history_for_prompt(history)
      out.should.include "[r1] rollbackOf=r0 s"
      out.should.include "applied create memory:a, failed delete skill:b"
      R.history_for_prompt([]).should == "No prior refinement history."
    end
  end

  describe "engine" do
    def fake_llm(response)
      ->(system:, user:, max_tokens:) { response }
    end

    def engine_env
      Dir.mktmpdir do |dir|
        store = PrimeAgent::HarnessStore.new(dir, scope: "local")
        yield store
      end
    end

    it "plan assembles the tagged prompt and parses the JSON reply" do
      captured = nil
      llm = lambda do |system:, user:, max_tokens:|
        captured = { system: system, user: user, max_tokens: max_tokens }
        %q({"summary": "learned rg", "edits": []})
      end
      engine = R::Engine.new(llm: llm)
      engine_env do |store|
        proposal, id = engine.plan(messages: [Brute::Message.new(role: :user, content: "hello")],
                                   state: store.state, history: [],
                                   instructions: "note the rg lesson", scope: "local")
        proposal[:summary].should == "learned rg"
        id.should.start_with "refine_"
        captured[:system].should.include "/refine continual harness subsystem"
        captured[:user].should.include "<current_harness_state>"
        captured[:user].should.include "[User]: hello"
        captured[:user].should.include "<user_refine_instructions>\nnote the rg lesson"
        captured[:user].should.include "Requested refinement scope: local."
        captured[:max_tokens].should == 32_000
      end
    end

    it "review parses the gate decision" do
      engine = R::Engine.new(llm: fake_llm(%q({"shouldRefine": true, "rationale": "rg lesson", "instructions": "save it"})))
      engine_env do |store|
        review = engine.review(messages: [], state: store.state, history: [],
                               reason: "turn_interval", turns_since_last_review: 25)
        review[:should_refine].should.be.true
        review[:rationale].should == "rg lesson"
        review[:instructions].should == "save it"
      end
    end
  end
end
