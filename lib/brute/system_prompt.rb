# frozen_string_literal: true

require "bundler/setup"
require "brute"

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

test do
  def base_ctx
    { provider_name: "anthropic", model_name: "test-model", cwd: Dir.pwd,
      custom_rules: nil, agent: nil, agent_switched: nil, max_steps_reached: nil }
  end

  it "stores a block and executes it on prepare" do
    sp = Brute::SystemPrompt.build { |p, ctx| p << "hello #{ctx[:name]}" }
    sp.prepare(name: "world").to_s.should == "hello world"
  end

  it "returns a Result with sections" do
    sp = Brute::SystemPrompt.build { |p, _| p << "section one"; p << "section two" }
    sp.prepare({}).sections.should == ["section one", "section two"]
  end

  it "strips nil and empty sections" do
    sp = Brute::SystemPrompt.build { |p, _| p << "kept"; p << nil; p << ""; p << "also kept" }
    sp.prepare({}).sections.should == ["kept", "also kept"]
  end

  it "joins sections with double newlines via to_s" do
    Brute::SystemPrompt::Result.new(["a", "b", "c"]).to_s.should == "a\n\nb\n\nc"
  end

  it "reports empty? correctly for empty result" do
    Brute::SystemPrompt::Result.new([]).empty?.should.be.true
  end

  it "reports empty? correctly for non-empty result" do
    Brute::SystemPrompt::Result.new(["a"]).empty?.should.be.false
  end

  it "falls back to default stack for unknown providers" do
    builder = Brute::SystemPrompt.default
    default_r = builder.prepare(base_ctx.merge(provider_name: "default"))
    unknown_r = builder.prepare(base_ctx.merge(provider_name: "unknown_provider"))
    unknown_r.sections.size.should == default_r.sections.size
  end

  it "includes PlanReminder when agent is plan" do
    builder = Brute::SystemPrompt.default
    builder.prepare(base_ctx.merge(agent: "plan")).to_s.should =~ /READ-ONLY/
  end

  it "excludes PlanReminder when agent is build" do
    builder = Brute::SystemPrompt.default
    (builder.prepare(base_ctx.merge(agent: "build")).to_s =~ /Plan Mode - System Reminder/).should.be.nil
  end

  it "includes BuildSwitch when agent_switched is build" do
    builder = Brute::SystemPrompt.default
    builder.prepare(base_ctx.merge(agent_switched: "build")).to_s.should =~ /operational mode has changed/
  end

  it "excludes BuildSwitch when agent_switched is nil" do
    builder = Brute::SystemPrompt.default
    (builder.prepare(base_ctx.merge(agent_switched: nil)).to_s =~ /operational mode has changed/).should.be.nil
  end

  it "includes MaxSteps when max_steps_reached" do
    builder = Brute::SystemPrompt.default
    builder.prepare(base_ctx.merge(max_steps_reached: true)).to_s.should =~ /MAXIMUM STEPS REACHED/
  end

  it "excludes MaxSteps when max_steps_reached is nil" do
    builder = Brute::SystemPrompt.default
    (builder.prepare(base_ctx.merge(max_steps_reached: nil)).to_s =~ /MAXIMUM STEPS REACHED/).should.be.nil
  end

  it "anthropic stack includes conventions" do
    builder = Brute::SystemPrompt.default
    builder.prepare(base_ctx.merge(provider_name: "anthropic")).to_s.should =~ /Following conventions/
  end

  it "openai stack includes conventions" do
    builder = Brute::SystemPrompt.default
    builder.prepare(base_ctx.merge(provider_name: "openai")).to_s.should =~ /Following conventions/
  end

  it "google stack includes conventions" do
    builder = Brute::SystemPrompt.default
    builder.prepare(base_ctx.merge(provider_name: "google")).to_s.should =~ /Following conventions/
  end
end
