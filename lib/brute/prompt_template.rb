# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "erb"

module Brute
  # An ERB-backed system-prompt object for Middleware::SystemPrompt — the
  # open alternative to Brute::SystemPrompt's built-in section stacks. You
  # bring a template and named values; every keyword becomes an attr_accessor
  # and an ERB local of the same name:
  #
  #   prompt = Brute::PromptTemplate.new(
  #     "prompt.erb",
  #     identity: "You are Pico.",
  #     memory:   -> { File.read("memory/MEMORY.md") },   # zero-arity proc
  #     env:      ->(ctx) { Brute::Prompts::Environment.call(ctx) },
  #   )
  #   prompt.identity = "You are Brute."   # attr_accessor per section
  #
  #   Brute.agent.use(Brute::Middleware::SystemPrompt, system_prompt: prompt)
  #
  # Proc values are re-evaluated on every prepare (zero-arity procs are
  # called with no arguments, others receive the turn ctx), and a template
  # path is re-read from disk each time — so file-backed sections hot-reload
  # between turns. The prepare(ctx) -> Result(#empty?, #to_s) contract is
  # what Middleware::SystemPrompt expects.
  class PromptTemplate
    Result = Struct.new(:text) do
      def to_s = text.to_s
      def empty? = text.to_s.strip.empty?
    end

    def initialize(template, **sections)
      @template = template
      @section_keys = []
      sections.each { |key, value| self[key] = value }
    end

    def [](key)
      public_send(key)
    end

    def []=(key, value)
      unless respond_to?(key)
        singleton_class.class_eval { attr_accessor key }
        @section_keys << key
      end
      public_send("#{key}=", value)
    end

    # Called once per turn by Middleware::SystemPrompt.
    def prepare(ctx = {})
      Result.new(render(locals(ctx)))
    end

    private

    def locals(ctx)
      @section_keys.to_h do |key|
        value = self[key]
        resolved = value.is_a?(Proc) ? (value.arity.zero? ? value.call : value.call(ctx)) : value
        [key, resolved]
      end.merge(ctx: ctx)
    end

    def render(values)
      context = binding
      values.each { |key, value| context.local_variable_set(key, value) }
      ERB.new(template_source, trim_mode: "-").result(context)
    end

    # A path that exists is re-read every time; anything else is treated as
    # an inline ERB source string.
    def template_source
      File.exist?(@template.to_s) ? File.read(@template) : @template.to_s
    end
  end
end

__END__

describe "brute/prompt_template" do
  require "tmpdir"

  it "renders keyword sections as ERB locals" do
    prompt = Brute::PromptTemplate.new("Hello <%= name %>, <%= mood %> today.", name: "Pico", mood: "happy")
    prompt.prepare.to_s.should == "Hello Pico, happy today."
  end

  it "exposes an attr_accessor per section" do
    prompt = Brute::PromptTemplate.new("<%= name %>", name: "Pico")
    prompt.name.should == "Pico"
    prompt.name = "Brute"
    prompt.prepare.to_s.should == "Brute"
  end

  it "re-evaluates zero-arity procs on every prepare" do
    count = 0
    prompt = Brute::PromptTemplate.new("<%= tick %>", tick: -> { count += 1 })
    prompt.prepare.to_s.should == "1"
    prompt.prepare.to_s.should == "2"
  end

  it "passes ctx to procs that take an argument" do
    prompt = Brute::PromptTemplate.new("<%= who %>", who: ->(ctx) { ctx[:agent] })
    prompt.prepare(agent: "pico").to_s.should == "pico"
  end

  it "re-reads a template file on every prepare" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "prompt.erb")
      File.write(path, "v1 <%= x %>")
      prompt = Brute::PromptTemplate.new(path, x: "a")
      prompt.prepare.to_s.should == "v1 a"
      File.write(path, "v2 <%= x %>")
      prompt.prepare.to_s.should == "v2 a"
    end
  end

  it "honours the Result contract (empty?/to_s)" do
    Brute::PromptTemplate.new("").prepare.empty?.should.be.true
    Brute::PromptTemplate.new("hi").prepare.empty?.should.be.false
  end
end
