# frozen_string_literal: true

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

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Prompts::Environment do
    it "includes cwd from context" do
      text = described_class.call(cwd: "/some/path", model_name: "test")
      expect(text).to include("/some/path")
    end

    it "includes model name from context" do
      text = described_class.call(cwd: "/tmp", model_name: "claude-sonnet-4-20250514")
      expect(text).to include("claude-sonnet-4-20250514")
    end

    it "wraps environment info in <env> tags" do
      text = described_class.call(cwd: "/tmp", model_name: "test")
      expect(text).to include("<env>")
      expect(text).to include("</env>")
    end

    it "detects git repo when .git exists" do
      Dir.mktmpdir do |dir|
        Dir.mkdir(File.join(dir, ".git"))
        text = described_class.call(cwd: dir, model_name: "test")
        expect(text).to include("Is directory a git repo: yes")
      end
    end

    it "detects non-git directory" do
      Dir.mktmpdir do |dir|
        text = described_class.call(cwd: dir, model_name: "test")
        expect(text).to include("Is directory a git repo: no")
      end
    end

    it "includes the platform" do
      text = described_class.call(cwd: "/tmp", model_name: "test")
      expect(text).to include(RUBY_PLATFORM)
    end

    it "defaults cwd to Dir.pwd when not provided" do
      text = described_class.call(model_name: "test")
      expect(text).to include(Dir.pwd)
    end
  end
end
