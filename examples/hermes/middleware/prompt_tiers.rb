# frozen_string_literal: true

require "fileutils"
require_relative "../prompt_texts"
require_relative "../context_files"

module Hermes
  module Middleware
    # PromptTiers — the byte-stable three-tier system prompt (per-turn).
    # Full port of hermes-agent agent/system_prompt.py
    # (build_system_prompt_parts + _restore_or_build_system_prompt).
    #
    # Tiers, joined stable → context → volatile:
    #   stable   — identity (SOUL.md or default), guidance blocks (tool-gated),
    #              model-family steering, environment hints, workspace snapshot.
    #   context  — caller system message + project context files (AGENTS.md…).
    #   volatile — skills index (front of band), memory blocks, timestamp line.
    #
    # Lifecycle:
    #   * built once per session, persisted to `session_path`, and restored
    #     VERBATIM on later turns when the runtime identity (Model/Provider/
    #     Platform lines) still matches — the prefix cache is sacred.
    #   * rebuilt only on compression: set env[:invalidate_system_prompt] = true
    #     before the turn (Compaction does this) and the prompt is rebuilt —
    #     picking up live memory/skills — then persisted again.
    #   * date-only timestamp keeps the prompt byte-stable for the whole day.
    #
    # Succeeds Brute::Middleware::SystemPrompt (which it replaces in the stack).
    class PromptTiers
      include Hermes::PromptTexts

      def initialize(app,
                     session_path: File.join(Dir.pwd, "sessions", "system_prompt.txt"),
                     cwd: Dir.pwd,
                     model: nil, provider: nil, platform: "cli",
                     tools: [],
                     task_completion_guidance: true,
                     parallel_tool_call_guidance: true,
                     tool_use_enforcement: "auto",
                     environment_probe: true,
                     context_file_max_chars: ContextFiles::DEFAULT_MAX_CHARS)
        @app = app
        @session_path = session_path
        @cwd = cwd
        @model = model
        @provider = provider
        @platform = platform
        @tools = tools.map { |t| t.respond_to?(:name) ? t.name.to_s : t[:name].to_s }
        @task_completion_guidance = task_completion_guidance
        @parallel_tool_call_guidance = parallel_tool_call_guidance
        @tool_use_enforcement = tool_use_enforcement
        @environment_probe = environment_probe
        @context_file_max_chars = context_file_max_chars
      end

      def call(env)
        unless env[:messages].any? { |m| m.role == :system }
          prompt = restore_or_build(env)
          env[:messages].unshift(Brute::Message.new(role: :system, content: prompt)) unless prompt.empty?
        end
        @app.call(env)
      end

      private

      # Restore the persisted prompt verbatim when the runtime identity still
      # matches; rebuild (and persist) on first build, staleness, or an
      # explicit invalidation (compression).
      def restore_or_build(env)
        stored = read_stored
        if env[:invalidate_system_prompt]
          # Compression rebuilt history: re-render so the volatile band picks
          # up live memory/skills, then persist the new bytes.
          return persist(build(env))
        end
        return stored if stored && runtime_matches?(stored)

        persist(build(env))
      end

      def read_stored
        File.exist?(@session_path) ? File.read(@session_path, encoding: Encoding::UTF_8) : nil
      end

      def persist(prompt)
        FileUtils.mkdir_p(File.dirname(@session_path))
        tmp = "#{@session_path}.tmp"
        File.write(tmp, prompt, encoding: Encoding::UTF_8)
        File.rename(tmp, @session_path)
        prompt
      end

      # The volatile tail carries "Model:"/"Provider:"/"Platform:" lines; a
      # stored prompt whose identity lines disagree with this runtime is stale.
      # Last matching line wins (the identity lines are emitted last).
      def runtime_matches?(stored)
        {
          "Model" => @model,
          "Provider" => @provider,
          "Platform" => @platform,
        }.all? do |label, current|
          current.nil? || line_value(stored, label) == current.to_s
        end
      end

      def line_value(prompt, label)
        prompt.each_line.select { |l| l.start_with?("#{label}:") }
              .map { |l| l.split(":", 2).last.strip }.last.to_s
      end

      # -- Assembly ------------------------------------------------------------

      def build(env)
        tiers = [stable_tier, context_tier(env), volatile_tier(env)]
        tiers.map { |t| t.strip }.reject(&:empty?).join("\n\n")
      end

      def stable_tier
        parts = []

        soul = ContextFiles.load_soul(dir: @cwd, max_chars: @context_file_max_chars)
        parts << (soul || DEFAULT_AGENT_IDENTITY)
        parts << HERMES_AGENT_HELP_GUIDANCE
        parts << TASK_COMPLETION_GUIDANCE if @task_completion_guidance && tools?
        parts << PARALLEL_TOOL_CALL_GUIDANCE if @parallel_tool_call_guidance && tools?

        guidance = []
        guidance << MEMORY_GUIDANCE if tool?("memory")
        guidance << SESSION_SEARCH_GUIDANCE if tool?("session_search")
        guidance << SKILLS_GUIDANCE if tool?("skill_manage")
        parts << guidance.join(" ") unless guidance.empty?

        parts << STEER_CHANNEL_NOTE if tools?

        enforcement = enforcement_guidance
        parts << enforcement if enforcement

        parts << environment_hints

        parts.compact.map(&:strip).reject(&:empty?).join("\n\n")
      end

      def context_tier(env)
        parts = []
        # Live workspace snapshot heads the context tier (hermes places the
        # git/workspace snapshot behind its own cache boundary).
        snapshot = workspace_snapshot
        parts << snapshot if snapshot
        parts << env[:system_message].to_s unless env[:system_message].to_s.empty?
        project = ContextFiles.build_prompt(
          cwd: @cwd,
          skip_soul: true, # SOUL.md already occupied the identity slot
          max_chars: @context_file_max_chars,
        )
        parts << project unless project.empty?
        parts.map(&:strip).reject(&:empty?).join("\n\n")
      end

      def volatile_tier(env)
        parts = []
        meta = env[:metadata] || {}

        # Skills index at the FRONT of the band: on longest-prefix caches an
        # unchanged index still falls inside the reused prefix on rebuilds.
        parts << meta[:skills_prompt] unless meta[:skills_prompt].to_s.empty?

        blocks = meta[:memory_blocks] || {}
        parts << blocks[:memory] unless blocks[:memory].to_s.empty?
        parts << blocks[:user] unless blocks[:user].to_s.empty?

        parts << timestamp_line
        parts.map(&:strip).reject(&:empty?).join("\n\n")
      end

      # Date-only: minute precision would bust the prefix cache on every
      # rebuild. The model can query wall-clock time via tools when needed.
      def timestamp_line
        line = "Conversation started: #{Time.now.strftime('%A, %B %d, %Y')}"
        line += "\nModel: #{@model}" if @model
        line += "\nProvider: #{@provider}" if @provider
        line += "\nPlatform: #{@platform}" if @platform
        line
      end

      # -- Stable-tier helpers ---------------------------------------------------

      def tools? = !@tools.empty?
      def tool?(name) = @tools.include?(name)

      # Tool-use enforcement: "auto" matches the model-family substrings;
      # true/false force; a list matches custom substrings. Model-family
      # guidance rides along (google / openai-gpt-grok).
      def enforcement_guidance
        return nil unless tools?

        model = @model.to_s.downcase
        inject =
          case @tool_use_enforcement
          when true then true
          when false, nil then false
          when Array then @tool_use_enforcement.any? { |p| model.include?(p.to_s.downcase) }
          else # "auto"
            TOOL_USE_ENFORCEMENT_MODELS.any? { |p| model.include?(p) }
          end
        return nil unless inject

        parts = [TOOL_USE_ENFORCEMENT_GUIDANCE]
        parts << GOOGLE_MODEL_OPERATIONAL_GUIDANCE if model.include?("gemini") || model.include?("gemma")
        if model.include?("gpt") || model.include?("codex") || model.include?("grok")
          parts << OPENAI_MODEL_EXECUTION_GUIDANCE
        end
        parts.join("\n\n")
      end

      # Host facts for the local terminal backend (remote backends suppress
      # host info in hermes — we only have local).
      def environment_hints
        require "rbconfig"
        host = "#{RbConfig::CONFIG['host_os']} (#{RbConfig::CONFIG['host_cpu']})"
        lines = [
          "Host: #{host}",
          "User home directory: #{Dir.home}",
          "Current working directory: #{@cwd}",
        ]
        probe = environment_probe_line
        lines << probe if probe
        lines.join("\n")
      end

      # One line naming non-default toolchain state; emits NOTHING when the
      # environment is clean (no token cost).
      def environment_probe_line
        return nil unless @environment_probe

        missing = %w[python3 pip uv].reject { |cmd| system("command -v #{cmd} >/dev/null 2>&1") }
        return nil if missing.empty?

        "Python toolchain: #{missing.join(', ')} not on PATH — check before relying on them."
      end

      # Live workspace snapshot for the context tier boundary: git branch +
      # dirty state. Empty outside a git worktree.
      def workspace_snapshot
        return nil unless ContextFiles.git_root(@cwd)

        branch = `git -C #{@cwd} branch --show-current 2>/dev/null`.strip
        dirty = `git -C #{@cwd} status --porcelain 2>/dev/null`.lines.size
        return nil if branch.empty?

        "## Workspace\n\nGit branch: #{branch}#{dirty.positive? ? " (#{dirty} uncommitted change#{'s' if dirty != 1})" : ' (clean)'}"
      rescue StandardError
        nil
      end
    end
  end
end
