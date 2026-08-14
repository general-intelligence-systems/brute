# frozen_string_literal: true

require "erb"

require "bundler/setup"
require "brute"

module Brute
  module Prompts
    TEXT_DIR = File.expand_path("text", __dir__)

    # Resolve a provider-specific text file.
    # Looks for +section/provider_name.txt+, falls back to +section/default.txt+.
    def self.read(section, provider_name)
      provider = provider_name.to_s
      path = File.join(TEXT_DIR, section, "#{provider}.txt")
      path = File.join(TEXT_DIR, section, "default.txt") unless File.exist?(path)
      return nil unless File.exist?(path)
      File.read(path)
    end

    # Read a named agent prompt (e.g. "explore", "compaction").
    def self.agent_prompt(name)
      path = File.join(TEXT_DIR, "agents", "#{name}.txt")
      File.exist?(path) ? File.read(path) : nil
    end

    # Template context handed to ERB templates. Context-hash keys become
    # methods (<%= skills %>, <%= cwd %>), plus view helpers like +h+.
    class Context
      def initialize(ctx)
        @ctx = ctx
      end

      def method_missing(name, *args)
        return @ctx[name] if args.empty? && @ctx.key?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @ctx.key?(name) || super
      end

      # XML-escape a value for prompt markup (& < > " ').
      def escape_xml(value)
        value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
           .gsub('"', "&quot;").gsub("'", "&apos;")
      end
      alias h escape_xml

      def get_binding
        binding
      end
    end

    # Compiled templates, keyed by absolute path. Compilation is idempotent,
    # so a racy double-assign under Async is harmless.
    TEMPLATES = {}

    # Resolve and render text/<section>/<provider>.erb, falling back to
    # default.erb, then to the legacy plain .txt files. Returns nil when the
    # section has no template or text file at all.
    #
    # Templates are ERB: arbitrary Ruby. Only ship templates with the gem or
    # load them from paths you trust.
    def self.render(section, ctx)
      provider = ctx[:provider_name].to_s
      path = [provider, "default"]
             .map { |variant| File.join(TEXT_DIR, section, "#{variant}.erb") }
             .find { |candidate| File.exist?(candidate) }
      return read(section, provider) unless path

      erb = TEMPLATES[path] ||= ERB.new(File.read(path), trim_mode: "-")
      erb.result(Context.new(ctx).get_binding)
    end
  end
end

__END__

describe "brute/prompts/base" do
  require "tmpdir"
  require "fileutils"

  it "interpolates ctx keys as methods" do
    ctx = Brute::Prompts::Context.new(name: "debugging")
    template = ERB.new("<%= name %>")
    template.result(ctx.get_binding).should == "debugging"
  end

  it "escapes XML via h" do
    ctx = Brute::Prompts::Context.new({})
    ctx.h(%q{a<b>&"c'}).should == "a&lt;b&gt;&amp;&quot;c&apos;"
  end

  it "renders a section template with provider fallback" do
    section = "base_test_render"
    dir = File.join(Brute::Prompts::TEXT_DIR, section)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "default.erb"), "hello <%= thing %>")
    begin
      Brute::Prompts.render(section, provider_name: "nope", thing: "world").should == "hello world"
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  it "prefers a provider-specific template over default" do
    section = "base_test_provider"
    dir = File.join(Brute::Prompts::TEXT_DIR, section)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "default.erb"), "default")
    File.write(File.join(dir, "anthropic.erb"), "anthropic")
    begin
      Brute::Prompts.render(section, provider_name: "anthropic").should == "anthropic"
      Brute::Prompts.render(section, provider_name: "openai").should == "default"
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  it "falls back to a legacy plain text file when no template exists" do
    Brute::Prompts.render("identity", provider_name: "anthropic").should ==
      Brute::Prompts.read("identity", "anthropic")
  end

  it "returns nil for a section with no template or text file" do
    Brute::Prompts.render("no_such_section_anywhere", provider_name: "x").should.be.nil
  end
end
