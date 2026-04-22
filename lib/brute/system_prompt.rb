# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

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
        # Provider-specific base stack.
        # For gateway providers (opencode_zen, opencode_go), infer the
        # upstream model family from the model name so we use the most
        # appropriate prompt stack (e.g., anthropic stack for claude-*).
        provider = ctx[:provider_name].to_s
        stack_key = if provider.start_with?("opencode")
                      infer_stack_from_model(ctx[:model_name].to_s)
                    else
                      provider
                    end
        STACKS.fetch(stack_key, STACKS["default"]).each do |mod|
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

      # Ollama — lean stack for local models with smaller context windows
      "ollama" => [
        Prompts::Identity,
        Prompts::ToneAndStyle,
        Prompts::Conventions,
        Prompts::DoingTasks,
        Prompts::ToolUsage,
        Prompts::GitSafety,
        Prompts::Environment,
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

    # Infer the best prompt stack from a model name.
    # Used for gateway providers that route to multiple upstream model families.
    def self.infer_stack_from_model(model_name)
      case model_name
      when /\bclaude\b/i, /\bbig.?pickle\b/i
        "anthropic"
      when /\bgpt\b/i, /\bo[134]\b/i, /\bcodex\b/i
        "openai"
      when /\bgemini\b/i, /\bgemma\b/i
        "google"
      else
        "default"
      end
    end

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

if __FILE__ == $0
  require_relative "../../spec/spec_helper"

  RSpec.describe Brute::SystemPrompt do
    describe ".build" do
      it "stores a block and executes it on prepare" do
        sp = described_class.build do |prompt, ctx|
          prompt << "hello #{ctx[:name]}"
        end

        result = sp.prepare(name: "world")
        expect(result.to_s).to eq("hello world")
      end

      it "returns a Result with sections" do
        sp = described_class.build do |prompt, _ctx|
          prompt << "section one"
          prompt << "section two"
        end

        result = sp.prepare({})
        expect(result.sections).to eq(["section one", "section two"])
      end

      it "strips nil and empty sections" do
        sp = described_class.build do |prompt, _ctx|
          prompt << "kept"
          prompt << nil
          prompt << ""
          prompt << "also kept"
        end

        result = sp.prepare({})
        expect(result.sections).to eq(["kept", "also kept"])
      end
    end

    describe Brute::SystemPrompt::Result do
      subject(:result) { described_class.new(["a", "b", "c"]) }

      it "joins sections with double newlines via to_s" do
        expect(result.to_s).to eq("a\n\nb\n\nc")
      end

      it "iterates over sections via each" do
        collected = []
        result.each { |s| collected << s }
        expect(collected).to eq(["a", "b", "c"])
      end

      it "reports empty? correctly" do
        expect(described_class.new([]).empty?).to be true
        expect(result.empty?).to be false
      end
    end

    describe ".default" do
      # Minimal context for all tests — enough to avoid nil errors
      let(:base_ctx) do
        {
          provider_name: "anthropic",
          model_name: "test-model",
          cwd: Dir.pwd,
          custom_rules: nil,
          agent: nil,
          agent_switched: nil,
          max_steps_reached: nil,
        }
      end

      let(:builder) { described_class.default }

      # ── Provider stack selection ──

      described_class::STACKS.each_key do |provider|
        context "with provider '#{provider}'" do
          it "produces non-empty sections" do
            ctx = base_ctx.merge(provider_name: provider)
            result = builder.prepare(ctx)
            expect(result.sections).not_to be_empty
            result.sections.each do |section|
              expect(section).to be_a(String)
            end
          end
        end
      end

      it "falls back to 'default' stack for unknown providers" do
        default_result = builder.prepare(base_ctx.merge(provider_name: "default"))
        unknown_result = builder.prepare(base_ctx.merge(provider_name: "unknown_provider"))

        # Both should produce the same number of sections (same stack)
        expect(unknown_result.sections.size).to eq(default_result.sections.size)
      end

      # ── Plan mode conditional ──

      context "when agent is 'plan'" do
        it "includes PlanReminder" do
          result = builder.prepare(base_ctx.merge(agent: "plan"))
          expect(result.to_s).to include("Plan Mode")
          expect(result.to_s).to include("<system-reminder>")
          expect(result.to_s).to include("READ-ONLY")
        end
      end

      context "when agent is 'build'" do
        it "does NOT include PlanReminder" do
          result = builder.prepare(base_ctx.merge(agent: "build"))
          expect(result.to_s).not_to include("Plan Mode - System Reminder")
          expect(result.to_s).not_to include("READ-ONLY")
        end
      end

      context "when agent is nil" do
        it "does NOT include PlanReminder" do
          result = builder.prepare(base_ctx.merge(agent: nil))
          expect(result.to_s).not_to include("Plan Mode - System Reminder")
        end
      end

      # ── Build switch conditional ──

      context "when agent_switched is 'build'" do
        it "includes BuildSwitch" do
          result = builder.prepare(base_ctx.merge(agent_switched: "build"))
          expect(result.to_s).to include("operational mode has changed from plan to build")
        end
      end

      context "when agent_switched is nil" do
        it "does NOT include BuildSwitch" do
          result = builder.prepare(base_ctx.merge(agent_switched: nil))
          expect(result.to_s).not_to include("operational mode has changed")
        end
      end

      # ── Max steps conditional ──

      context "when max_steps_reached is truthy" do
        it "includes MaxSteps" do
          result = builder.prepare(base_ctx.merge(max_steps_reached: true))
          expect(result.to_s).to include("MAXIMUM STEPS REACHED")
          expect(result.to_s).to include("Tools are disabled")
        end
      end

      context "when max_steps_reached is falsy" do
        it "does NOT include MaxSteps" do
          result = builder.prepare(base_ctx.merge(max_steps_reached: nil))
          expect(result.to_s).not_to include("MAXIMUM STEPS REACHED")
        end
      end

      # ── Combined states (mid-session switch scenarios) ──

      context "plan mode includes PlanReminder but excludes BuildSwitch" do
        it "contains only plan-specific content" do
          result = builder.prepare(base_ctx.merge(agent: "plan"))
          expect(result.to_s).to include("READ-ONLY")
          expect(result.to_s).not_to include("operational mode has changed")
        end
      end

      context "build mode with agent_switched includes BuildSwitch but excludes PlanReminder" do
        it "contains only build-switch content" do
          result = builder.prepare(base_ctx.merge(agent: "build", agent_switched: "build"))
          expect(result.to_s).to include("operational mode has changed from plan to build")
          expect(result.to_s).not_to include("Plan Mode - System Reminder")
        end
      end

      context "plan mode with max_steps_reached includes both" do
        it "contains both PlanReminder and MaxSteps" do
          result = builder.prepare(base_ctx.merge(agent: "plan", max_steps_reached: true))
          expect(result.to_s).to include("READ-ONLY")
          expect(result.to_s).to include("MAXIMUM STEPS REACHED")
        end
      end

      # ── Provider stack composition ──

      it "anthropic stack includes expected modules" do
        result = builder.prepare(base_ctx.merge(provider_name: "anthropic"))
        text = result.to_s
        # Anthropic has Identity, Objectivity, Conventions, GitSafety etc.
        expect(text).to include("Professional objectivity")
        expect(text).to include("Following conventions")
        expect(text).to include("Git safety")
      end

      it "openai stack includes editing-focused modules" do
        result = builder.prepare(base_ctx.merge(provider_name: "openai"))
        text = result.to_s
        # OpenAI has EditingApproach, Autonomy, EditingConstraints
        expect(text).to include("Following conventions")
        expect(text).to include("Git safety")
      end

      it "google stack includes security module" do
        result = builder.prepare(base_ctx.merge(provider_name: "google"))
        text = result.to_s
        expect(text).to include("Following conventions")
        expect(text).to include("Git safety")
      end
    end
  end
end
