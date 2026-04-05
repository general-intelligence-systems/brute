# frozen_string_literal: true

module Brute
  # Builds the system prompt dynamically based on available tools, environment,
  # custom rules, and working directory context.
  #
  # Modeled after forgecode's SystemPrompt which composes a static agent
  # personality block with dynamic environment/tool information.
  class SystemPrompt
    def initialize(cwd: Dir.pwd, tools: [], custom_rules: nil)
      @cwd = cwd
      @tools = tools
      @custom_rules = custom_rules
    end

    def build
      sections = []
      sections << identity_section
      sections << tools_section
      sections << guidelines_section
      sections << environment_section
      sections << custom_rules_section if @custom_rules
      sections.compact.join("\n\n")
    end

    private

    def identity_section
      <<~SECTION
        # Identity

        You are Brute, an expert software engineering agent. You help users with coding tasks
        by reading, writing, and editing files, running shell commands, and searching codebases.
        You are methodical, precise, and always verify your work.
      SECTION
    end

    def tools_section
      tool_list = LLM::Function.registry.filter_map { |fn|
        "- **#{fn.name}**: #{fn.description.to_s.split(". ").first}."
      }.join("\n")

      <<~SECTION
        # Available Tools

        #{tool_list}
      SECTION
    end

    def guidelines_section
      <<~SECTION
        # Guidelines

        - **Always read before editing**: Use `read` to examine a file before using `patch` or `write` to modify it.
        - **Verify your changes**: After editing, re-read the file or run tests to confirm correctness.
        - **Use todo_write for multi-step tasks**: Break complex work into steps and track progress.
        - **Use fs_search to find code**: Don't guess file locations — search first.
        - **Use shell for git, tests, builds**: Run `git diff`, `git status`, test suites, etc.
        - **Be precise with patch**: The `old_string` must match the file content exactly, including whitespace.
        - **Prefer patch over write**: For existing files, use `patch` to change specific sections rather than rewriting the entire file.
        - **Use undo to recover**: If a write or patch goes wrong, use `undo` to restore the previous version.
        - **Delegate research**: Use `delegate` for complex analysis that needs focused investigation.
      SECTION
    end

    def environment_section
      files = Dir.entries(@cwd).reject { |f| f.start_with?(".") }.sort.first(50)

      <<~SECTION
        # Environment

        - **Working directory**: #{@cwd}
        - **OS**: #{RUBY_PLATFORM}
        - **Ruby**: #{RUBY_VERSION}
        - **Date**: #{Time.now.strftime("%Y-%m-%d")}
        - **Files in cwd**: #{files.join(", ")}
      SECTION
    end

    def custom_rules_section
      <<~SECTION
        # Project-Specific Rules

        #{@custom_rules}
      SECTION
    end
  end
end
