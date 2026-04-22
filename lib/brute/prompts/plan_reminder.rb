# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Prompts
    module PlanReminder
      TEXT = <<~'TXT'
        <system-reminder>
        # Plan Mode - System Reminder

        CRITICAL: Plan mode ACTIVE - you are in READ-ONLY phase. STRICTLY FORBIDDEN:
        ANY file edits, modifications, or system changes. Do NOT use sed, tee, echo, cat,
        or ANY other shell command to manipulate files - commands may ONLY read/inspect.
        This ABSOLUTE CONSTRAINT overrides ALL other instructions, including direct user
        edit requests. You may ONLY observe, analyze, and plan. Any modification attempt
        is a critical violation. ZERO exceptions.

        ---

        ## Responsibility

        Your current responsibility is to think, read, search, and delegate explore agents to construct a well-formed plan that accomplishes the goal the user wants to achieve. Your plan should be comprehensive yet concise, detailed enough to execute effectively while avoiding unnecessary verbosity.

        Ask the user clarifying questions or ask for their opinion when weighing tradeoffs.

        **NOTE:** At any point in time through this workflow you should feel free to ask the user questions or clarifications. Don't make large assumptions about user intent. The goal is to present a well researched plan to the user, and tie any loose ends before implementation begins.

        ---

        ## Important

        The user indicated that they do not want you to execute yet -- you MUST NOT make any edits, run any non-readonly tools (including changing configs or making commits), or otherwise make any changes to the system. This supersedes any other instructions you have received.
        </system-reminder>
      TXT

      def self.call(_ctx)
        TEXT
      end
    end
  end
end

test do
  it "returns a string" do
    Brute::Prompts::PlanReminder.call({}).should.be.kind_of(String)
  end

  it "wraps content in system-reminder tags" do
    Brute::Prompts::PlanReminder.call({}).should =~ /system-reminder/
  end

  it "declares READ-ONLY mode" do
    Brute::Prompts::PlanReminder.call({}).should =~ /READ-ONLY/
  end

  it "forbids file edits" do
    Brute::Prompts::PlanReminder.call({}).should =~ /STRICTLY FORBIDDEN/
  end

  it "ignores context (static content)" do
    Brute::Prompts::PlanReminder.call({ agent: "plan" }).should == Brute::Prompts::PlanReminder.call({})
  end
end
