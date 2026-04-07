# frozen_string_literal: true

RSpec.describe Brute::Orchestrator, "system prompt" do
  let(:provider) { MockProvider.new }

  def build_orchestrator(agent_name: nil, cwd: Dir.pwd)
    described_class.new(
      provider: provider,
      model: "test-model",
      tools: [],
      cwd: cwd,
      agent_name: agent_name,
      logger: Logger.new(File::NULL),
    )
  end

  def system_prompt_for(orchestrator)
    orchestrator.instance_variable_get(:@system_prompt)
  end

  # ── Build mode (default) ──

  context "build mode (default, agent_name: nil)" do
    subject(:prompt) { system_prompt_for(build_orchestrator(agent_name: nil)) }

    it "does NOT contain PlanReminder" do
      expect(prompt).not_to include("Plan Mode - System Reminder")
      expect(prompt).not_to include("READ-ONLY")
    end

    it "does NOT contain BuildSwitch" do
      expect(prompt).not_to include("operational mode has changed")
    end

    it "does NOT contain MaxSteps" do
      expect(prompt).not_to include("MAXIMUM STEPS REACHED")
    end

    it "contains identity section" do
      expect(prompt).to include("Brute")
    end

    it "contains environment section" do
      expect(prompt).to include("<env>")
      expect(prompt).to include("Working directory:")
    end
  end

  context "build mode (explicit agent_name: 'build')" do
    subject(:prompt) { system_prompt_for(build_orchestrator(agent_name: "build")) }

    it "does NOT contain PlanReminder" do
      expect(prompt).not_to include("Plan Mode - System Reminder")
      expect(prompt).not_to include("READ-ONLY")
    end

    it "contains identity section" do
      expect(prompt).to include("Brute")
    end
  end

  # ── Plan mode ──

  context "plan mode (agent_name: 'plan')" do
    subject(:prompt) { system_prompt_for(build_orchestrator(agent_name: "plan")) }

    it "includes PlanReminder" do
      expect(prompt).to include("Plan Mode - System Reminder")
      expect(prompt).to include("<system-reminder>")
      expect(prompt).to include("READ-ONLY")
    end

    it "includes the supersede warning" do
      expect(prompt).to include("supersedes any other instructions")
    end

    it "does NOT include BuildSwitch" do
      expect(prompt).not_to include("operational mode has changed")
    end

    it "still includes identity section" do
      expect(prompt).to include("Brute")
    end

    it "still includes environment section" do
      expect(prompt).to include("<env>")
    end
  end

  # ── Switching from plan to build (simulating mid-session agent recreation) ──

  context "switching from plan to build (new orchestrator, same session)" do
    let(:session) { Brute::Session.new }

    it "plan orchestrator has PlanReminder, build orchestrator does not" do
      plan_orch = described_class.new(
        provider: provider,
        model: "test-model",
        tools: [],
        session: session,
        agent_name: "plan",
        logger: Logger.new(File::NULL),
      )
      plan_prompt = system_prompt_for(plan_orch)
      expect(plan_prompt).to include("READ-ONLY")

      build_orch = described_class.new(
        provider: provider,
        model: "test-model",
        tools: [],
        session: session,
        agent_name: "build",
        logger: Logger.new(File::NULL),
      )
      build_prompt = system_prompt_for(build_orch)
      expect(build_prompt).not_to include("READ-ONLY")
      expect(build_prompt).not_to include("Plan Mode")
    end

    it "build orchestrator does NOT contain BuildSwitch (agent_switched never set)" do
      build_orch = described_class.new(
        provider: provider,
        model: "test-model",
        tools: [],
        session: session,
        agent_name: "build",
        logger: Logger.new(File::NULL),
      )
      build_prompt = system_prompt_for(build_orch)
      # This documents the current behavior: BuildSwitch is dead code
      expect(build_prompt).not_to include("operational mode has changed from plan to build")
    end
  end

  # ── Provider-specific stacks ──

  context "provider-specific identity text" do
    it "uses mock provider (falls back to default stack)" do
      prompt = system_prompt_for(build_orchestrator)
      # MockProvider.name returns :mock, which isn't a known stack, so falls back to "default"
      expect(prompt).to be_a(String)
      expect(prompt).not_to be_empty
    end
  end

  # ── Working directory is embedded ──

  context "cwd propagation" do
    it "embeds the given cwd in the system prompt" do
      Dir.mktmpdir do |dir|
        prompt = system_prompt_for(build_orchestrator(cwd: dir))
        expect(prompt).to include(dir)
      end
    end
  end
end
