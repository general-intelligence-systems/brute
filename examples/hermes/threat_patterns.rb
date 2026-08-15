# frozen_string_literal: true

module Hermes
  # Injection/exfiltration pattern scanner — full port of hermes-agent
  # tools/threat_patterns.py (pattern table verbatim).
  #
  # Scopes cascade: "all" ⊂ "context" ⊂ "strict".
  #   "all"     — classic injection + exfil only (minimal false positives)
  #   "context" — + promptware / C2 / role-play (context files, tool results)
  #   "strict"  — + persistence / SSH backdoor / exfil-URL (user-mediated
  #               writes: memory tool, skills install)
  module ThreatPatterns
    # Hard cap on scanned text: keeps worst-case regex runtime predictable.
    MAX_SCAN_CHARS = 65_536

    # Bounded filler between attack keywords (no unbounded repetition).
    FILLER = "(?:\\w+\\s+){0,8}"

    # Invisible / bidirectional unicode characters used in injection attacks.
    INVISIBLE_CHARS = [
      0x200B, 0x200C, 0x200D, 0x2060, 0x2062, 0x2063, 0x2064, 0xFEFF,
      0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
    ].map { |cp| [cp].pack("U") }.freeze

    # Each entry: [regex source, pattern_id, scope]. Compiled once at load.
    PATTERNS = [
      # ── Classic prompt injection ──────────────────────────────────
      ["ignore\\s+#{FILLER}(previous|all|above|prior)\\s+#{FILLER}instructions", "prompt_injection", "all"],
      ["system\\s+prompt\\s+override", "sys_prompt_override", "all"],
      ["disregard\\s+#{FILLER}(your|all|any)\\s+#{FILLER}(instructions|rules|guidelines)", "disregard_rules", "all"],
      ["act\\s+as\\s+(if|though)\\s+#{FILLER}you\\s+#{FILLER}(have\\s+no|don't\\s+have)\\s+#{FILLER}(restrictions|limits|rules)", "bypass_restrictions", "all"],
      ["<!--[^>]{0,512}(?:ignore|override|system|secret|hidden)[^>]{0,512}-->", "html_comment_injection", "all"],
      ["<\\s*div\\s+style\\s*=\\s*[\"'][^>]{0,2048}display\\s*:\\s*none", "hidden_div", "all"],
      ["translate\\s+[^\\n]{0,512}\\s+into\\s+[^\\n]{0,512}\\s+and\\s+(execute|run|eval)", "translate_execute", "all"],
      ["do\\s+not\\s+#{FILLER}tell\\s+#{FILLER}the\\s+user", "deception_hide", "all"],

      # ── Role-play / identity hijack ───────────────────────────────
      ["you\\s+are\\s+#{FILLER}now\\s+(?:a|an|the)\\s+", "role_hijack", "context"],
      ["pretend\\s+#{FILLER}(you\\s+are|to\\s+be)\\s+", "role_pretend", "context"],
      ["output\\s+#{FILLER}(system|initial)\\s+prompt", "leak_system_prompt", "context"],
      ["(respond|answer|reply)\\s+without\\s+#{FILLER}(restrictions|limitations|filters|safety)", "remove_filters", "context"],
      ["you\\s+have\\s+been\\s+#{FILLER}(updated|upgraded|patched)\\s+to", "fake_update", "context"],
      ["\\bname\\s+yourself\\s+\\w+", "identity_override", "context"],

      # ── C2 / Brainworm-style promptware ───────────────────────────
      ["register\\s+(as\\s+)?a?\\s*node", "c2_node_registration", "context"],
      ["(heartbeat|beacon|check[\\s\\-]?in)\\s+(to|with)\\s+", "c2_heartbeat", "context"],
      ["pull\\s+(down\\s+)?(?:new\\s+)?task(?:ing|s)?\\b", "c2_task_pull", "context"],
      ["connect\\s+to\\s+the\\s+network\\b", "c2_network_connect", "context"],
      ["you\\s+must\\s+(?:\\w+\\s+){0,3}(register|connect|report|beacon)\\b", "forced_action", "context"],
      ["only\\s+use\\s+one[\\s\\-]?liners?\\b", "anti_forensic_oneliner", "context"],
      ["never\\s+#{FILLER}(?:create|write)\\s+#{FILLER}(?:script|file)\\s+#{FILLER}disk", "anti_forensic_disk", "context"],
      ["unset\\s+\\w*(?:CLAUDE|CODEX|HERMES|AGENT|OPENAI|ANTHROPIC)\\w*", "env_var_unset_agent", "context"],

      # ── Known C2 / red-team framework names ───────────────────────
      ["\\b(?:cobalt\\s*strike|sliver|havoc|mythic|metasploit|brainworm)\\b", "known_c2_framework", "context"],
      ["\\bc2\\s+(?:server|channel|infrastructure|beacon)\\b", "c2_explicit", "context"],
      ["\\bcommand\\s+and\\s+control\\b", "c2_explicit_long", "context"],

      # ── Exfiltration via curl/wget/cat with secrets ───────────────
      ["curl\\s+[^\\n]{0,2048}\\$\\{?\\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)", "exfil_curl", "all"],
      ["wget\\s+[^\\n]{0,2048}\\$\\{?\\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)", "exfil_wget", "all"],
      ["cat\\s+[^\\n]{0,2048}(\\.env|credentials|\\.netrc|\\.pgpass|\\.npmrc|\\.pypirc)", "read_secrets", "all"],
      ["(send|post|upload|transmit)\\s+[^\\n]{0,2048}\\s+(to|at)\\s+https?://", "send_to_url", "strict"],
      ["(include|output|print|share)\\s+#{FILLER}(conversation|chat\\s+history|previous\\s+messages|full\\s+context|entire\\s+context)", "context_exfil", "strict"],

      # ── Persistence / SSH backdoor ────────────────────────────────
      ["authorized_keys", "ssh_backdoor", "strict"],
      ["\\$HOME/\\.ssh|\\~/\\.ssh", "ssh_access", "strict"],
      ["\\$HOME/\\.hermes/\\.env|\\~/\\.hermes/\\.env", "hermes_env", "strict"],
      ["(update|modify|edit|write|change|append|add\\s+to)\\s+[^\\n]{0,2048}(?:AGENTS\\.md|CLAUDE\\.md|\\.cursorrules|\\.clinerules)", "agent_config_mod", "strict"],
      ["(update|modify|edit|write|change|append|add\\s+to)\\s+[^\\n]{0,2048}\\.hermes/(config\\.yaml|SOUL\\.md)", "hermes_config_mod", "strict"],

      # ── Hardcoded secrets ─────────────────────────────────────────
      ["(?:api[_-]?key|token|secret|password)\\s*[=:]\\s*[\"'][A-Za-z0-9+/=_-]{20,}", "hardcoded_secret", "strict"],
    ].freeze

    # Compiled pattern sets indexed by scope ("all" lands everywhere,
    # "context" lands in context+strict, "strict" in strict only).
    SCOPED = PATTERNS.each_with_object({ "all" => [], "context" => [], "strict" => [] }) do |(src, pid, scope), acc|
      entry = [Regexp.new(src, Regexp::IGNORECASE), pid]
      case scope
      when "all"     then acc["all"] << entry; acc["context"] << entry; acc["strict"] << entry
      when "context" then acc["context"] << entry; acc["strict"] << entry
      when "strict"  then acc["strict"] << entry
      else raise ArgumentError, "threat_patterns: unknown scope #{scope.inspect} for pattern #{pid.inspect}"
      end
    end.freeze

    module_function

    # Return matched pattern IDs in content at the given scope. Also flags
    # invisible unicode as "invisible_unicode_U+XXXX" (checked on the raw
    # content, before NFKC normalisation can strip codepoints).
    def scan_for_threats(content, scope: "context")
      return [] if content.nil? || content.empty?

      patterns = SCOPED[scope]
      raise ArgumentError, "scan_for_threats: unknown scope #{scope.inspect}" unless patterns

      findings = []
      content = content[0, MAX_SCAN_CHARS]

      (content.chars & INVISIBLE_CHARS).each do |ch|
        findings << format("invisible_unicode_U+%04X", ch.ord)
      end

      # NFKC folds full-width/compat variants (ｃａｔ → cat) before matching.
      normalised = content.unicode_normalize(:nfkc)
      patterns.each do |regex, pid|
        findings << pid if regex.match?(normalised)
      end

      findings
    end

    # Human-readable error string for the first threat found, or nil.
    def first_threat_message(content, scope: "strict")
      findings = scan_for_threats(content, scope: scope)
      return nil if findings.empty?

      pid = findings.first
      if pid.start_with?("invisible_unicode_")
        codepoint = pid.sub("invisible_unicode_", "")
        return "Blocked: content contains invisible unicode character #{codepoint} (possible injection)."
      end
      "Blocked: content matches threat pattern '#{pid}'. " \
        "Content is injected into the system prompt and must not contain " \
        "injection or exfiltration payloads."
    end
  end
end
