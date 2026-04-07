# frozen_string_literal: true

module Brute
  # Deferred system prompt builder.
  #
  # The block passed to +build+ is stored — not executed — until +prepare+
  # is called with a runtime context hash (provider_name, model_name, cwd, etc).
  #
  #   sp = Brute::SystemPrompt.build do |prompt, ctx|
  #     prompt << Brute::Prompts::Identity.call(ctx)
  #     prompt << Brute::Prompts::ToneAndStyle.call(ctx)
  #     prompt << Brute::Prompts::Environment.call(ctx)
  #   end
  #
  #   result = sp.prepare(provider_name: "anthropic", model_name: "claude-sonnet-4-20250514", cwd: Dir.pwd)
  #   result.to_s       # single joined string
  #   result.sections   # array of strings (one per p.system call)
  #
  class SystemPrompt
    # Build a deferred system prompt. The block is stored and called later by +prepare+.
    def self.build(&block)
      new(block)
    end

    # Return the default system prompt. Selects the right provider stack at
    # prepare-time, then appends conditional sections based on runtime state.
    def self.default
      build do |prompt, ctx|
        # Provider-specific base stack
        provider = ctx[:provider_name].to_s
        STACKS.fetch(provider, STACKS["default"]).each do |mod|
          prompt << mod.call(ctx)
        end

        # Conditional: agent-specific reminders
        if ctx[:agent] == "plan"
          prompt << Prompts::PlanReminder.call(ctx)
        end

        if ctx[:agent_switched] == "build"
          prompt << Prompts::BuildSwitch.call(ctx)
        end

        if ctx[:max_steps_reached]
          prompt << Prompts::MaxSteps.call(ctx)
        end
      end
    end

    # Pre-configured prompt stacks per provider.
    # Each maps a provider name to an ordered list of prompt modules.
    STACKS = {
      # Claude — full-featured with task management and detailed tool policy
      "anthropic" => [
        Prompts::Identity,
        Prompts::ToneAndStyle,
        Prompts::Objectivity,
        Prompts::TaskManagement,
        Prompts::DoingTasks,
        Prompts::ToolUsage,
        Prompts::Conventions,
        Prompts::GitSafety,
        Prompts::CodeReferences,
        Prompts::Environment,
        Prompts::Skills,
        Prompts::Instructions,
      ],

      # GPT-4 / o1 / o3 — pragmatic engineer persona, editing focus, autonomy
      "openai" => [
        Prompts::Identity,
        Prompts::EditingApproach,
        Prompts::Autonomy,
        Prompts::EditingConstraints,
        Prompts::FrontendTasks,
        Prompts::ToneAndStyle,
        Prompts::Conventions,
        Prompts::GitSafety,
        Prompts::CodeReferences,
        Prompts::Environment,
        Prompts::Skills,
        Prompts::Instructions,
      ],

      # Gemini — formal/structured, explicit workflows, security focus
      "google" => [
        Prompts::Identity,
        Prompts::Conventions,
        Prompts::DoingTasks,
        Prompts::ToneAndStyle,
        Prompts::SecurityAndSafety,
        Prompts::ToolUsage,
        Prompts::GitSafety,
        Prompts::CodeReferences,
        Prompts::Environment,
        Prompts::Skills,
        Prompts::Instructions,
      ],

      # Fallback — conservative, concise, fewer than 4 lines
      "default" => [
        Prompts::Identity,
        Prompts::ToneAndStyle,
        Prompts::Proactiveness,
        Prompts::Conventions,
        Prompts::CodeStyle,
        Prompts::DoingTasks,
        Prompts::ToolUsage,
        Prompts::GitSafety,
        Prompts::CodeReferences,
        Prompts::Environment,
        Prompts::Skills,
        Prompts::Instructions,
      ],
    }.freeze

    def initialize(block)
      @block = block
    end

    # Execute the stored block with the given context and return a Result.
    def prepare(ctx)
      sections = []
      @block.call(sections, ctx)
      Result.new(sections.compact.reject { |s| s.respond_to?(:empty?) && s.empty? })
    end

    # Immutable result of a prepared system prompt.
    Result = Struct.new(:sections) do
      def to_s
        sections.join("\n\n")
      end

      def each(&block)
        sections.each(&block)
      end

      def empty?
        sections.empty?
      end
    end
  end
end
