# frozen_string_literal: true

require_relative "../truncate"

module PrimeAgent
  module Middleware
    # ResultCaps — per-iteration middleware (wraps ToolPipeline). The port of
    # prime-agent's tool-output caps (core/tools/truncate.ts +
    # output-accumulator.ts), applied to tool results entering the
    # conversation.
    #
    # The caps in force on this stack, outermost last:
    #
    #   1. kernel cell caps — 65_536 chars per stream with
    #      "[... output truncated at N chars ...]" (KernelManager::Output,
    #      prime-agent's ipython cap; enforced since stage 1);
    #   2. THIS middleware — tail truncation at 2000 lines / 50 KB
    #      (Truncate::DEFAULT_MAX_LINES / DEFAULT_MAX_BYTES), keeping the end
    #      of tool output where errors and final results live (upstream's
    #      bash/tool-result semantics), with a kept-of-total notice;
    #   3. brute's universal net — Brute::Truncation inside ToolPipeline,
    #      same 2000-line / 50 KB limits, head-keep with a disk spill.
    #
    # Results already carrying a truncation marker (the kernel's notice or
    # brute's "[Output truncated:") pass through untouched — the first cap to
    # fire wins, exactly upstream's "whichever limit is hit first".
    class ResultCaps
      KERNEL_NOTICE = "[... output truncated at"
      BRUTE_MARKER = "[Output truncated:"

      def initialize(app, max_lines: Truncate::DEFAULT_MAX_LINES, max_bytes: Truncate::DEFAULT_MAX_BYTES)
        @app = app
        @max_lines = max_lines
        @max_bytes = max_bytes
      end

      def call(env)
        @app.call(env)
        env[:messages].each_with_index do |message, index|
          next unless message.role == :tool

          content = message.content
          next if content.nil? || content.empty? || already_truncated?(content)

          result = Truncate.truncate_tail(content, max_lines: @max_lines, max_bytes: @max_bytes)
          next unless result.truncated

          notice = "[... output truncated: showing last #{result.output_lines} of " \
                   "#{result.total_lines} lines (#{Truncate.format_size(result.output_bytes)} of " \
                   "#{Truncate.format_size(result.total_bytes)}) ...]"
          env[:messages][index] =
            Brute::Message.new(role: :tool, content: "#{result.content}\n#{notice}",
                               tool_call_id: message.tool_call_id)
        end
        env
      end

      private

      def already_truncated?(content)
        content.include?(KERNEL_NOTICE) || content.include?(BRUTE_MARKER)
      end
    end
  end
end

__END__

describe "prime_agent/middleware/result_caps" do
  require "brute/messages"

  def caps(max_lines: 3, max_bytes: 50 * 1024)
    app = lambda do |env|
      env[:messages].tool(@content, tool_call_id: "t1")
      env
    end
    PrimeAgent::Middleware::ResultCaps.new(app, max_lines: max_lines, max_bytes: max_bytes)
  end

  it "tail-truncates over-long tool results with a kept-of-total notice" do
    @content = (1..10).map { |i| "line #{i}" }.join("\n")
    env = { messages: Brute.log }
    caps.call(env)
    result = env[:messages].last.content
    result.should.include "line 8"
    result.should.include "line 10"
    result.should.not.include "line 1\n"
    result.should.include "showing last 3 of 10 lines"
  end

  it "leaves fitting results and already-truncated results untouched" do
    @content = "small"
    env = { messages: Brute.log }
    caps.call(env)
    env[:messages].last.content.should == "small"

    @content = "#{"x" * 100}\n[... output truncated at 65536 chars ...]"
    env = { messages: Brute.log }
    caps.call(env)
    env[:messages].last.content.should == @content
  end

  it "ignores non-tool messages" do
    app = ->(env) { env[:messages].assistant("a" * 100); env }
    env = { messages: Brute.log }
    PrimeAgent::Middleware::ResultCaps.new(app, max_lines: 1).call(env)
    env[:messages].last.content.should == "a" * 100
  end
end
