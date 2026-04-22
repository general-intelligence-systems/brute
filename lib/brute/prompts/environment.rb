# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Prompts
    module Environment
      def self.call(ctx)
        cwd = ctx[:cwd] || Dir.pwd
        model = ctx[:model_name].to_s
        git = File.exist?(File.join(cwd, ".git"))

        parts = []
        parts << "You are powered by the model named #{model}." unless model.empty?
        parts << ""
        parts << "Here is some useful information about the environment you are running in:"
        parts << "<env>"
        parts << "  Working directory: #{cwd}"
        parts << "  Is directory a git repo: #{git ? "yes" : "no"}"
        parts << "  Platform: #{RUBY_PLATFORM}"
        parts << "  Today's date: #{Time.now.strftime("%a %b %d %Y")}"
        parts << "</env>"
        parts.join("\n")
      end
    end
  end
end

test do
  require "tmpdir"
  require "fileutils"

  it "includes cwd from context" do
    Brute::Prompts::Environment.call(cwd: "/some/path", model_name: "test").should =~ /\/some\/path/
  end

  it "includes model name from context" do
    Brute::Prompts::Environment.call(cwd: "/tmp", model_name: "claude-sonnet").should =~ /claude-sonnet/
  end

  it "wraps environment info in env tags" do
    Brute::Prompts::Environment.call(cwd: "/tmp", model_name: "test").should =~ /<env>/
  end

  it "detects git repo when .git exists" do
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, ".git"))
      text = Brute::Prompts::Environment.call(cwd: dir, model_name: "test")
      text.should =~ /Is directory a git repo: yes/
    end
  end

  it "detects non-git directory" do
    Dir.mktmpdir do |dir|
      text = Brute::Prompts::Environment.call(cwd: dir, model_name: "test")
      text.should =~ /Is directory a git repo: no/
    end
  end

  it "includes the platform" do
    Brute::Prompts::Environment.call(cwd: "/tmp", model_name: "test").should =~ /#{RUBY_PLATFORM}/
  end

  it "defaults cwd to Dir.pwd when not provided" do
    Brute::Prompts::Environment.call(model_name: "test").should =~ /#{Regexp.escape(Dir.pwd)}/
  end
end
