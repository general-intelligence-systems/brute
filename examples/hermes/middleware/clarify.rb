# frozen_string_literal: true

require "timeout"
require_relative "../tools/clarify"

module Hermes
  module Middleware
    # Clarify — the mid-loop question (per-turn). Ports hermes-agent
    # tools/clarify_tool.py + clarify_gateway.py. Fills brute's unimplemented
    # Middleware::Question (060).
    #
    # Interactive: the tool blocks on stdin (numbered choices, 3600s timeout →
    # sentinel). Unattended (ticks, cron, subagents): the tool returns the
    # undeliverable sentinel immediately — never blocks a headless run.
    class Clarify
      TIMEOUT = 3600

      def initialize(app, unattended: false, prompter: nil)
        @app = app
        @unattended = unattended
        @prompter = prompter
      end

      def call(env)
        tool =
          if @unattended
            HermesTools::Clarify.new(unavailable_reason: "[clarify prompt could not be delivered — no user is present in this context]")
          else
            HermesTools::Clarify.new(prompter: @prompter || method(:default_prompter))
          end
        env[:provided_tools] = Array(env[:provided_tools]) << tool
        @app.call(env)
      end

      private

      # CLI prompt: numbered choices, read a number or free text, 3600s
      # timeout → nil (the sentinel path).
      def default_prompter(question, choices, multi_select)
        $stdout.puts "\n❓ #{question}"
        choices.each_with_index { |c, i| $stdout.puts "  #{i + 1}. #{c}" }
        $stdout.print "  > "
        answer = Timeout.timeout(TIMEOUT) { $stdin.gets&.strip }
        return nil if answer.nil? || answer.empty?

        if answer =~ /\A\d+\z/ && (1..choices.size).cover?(answer.to_i)
          choices[answer.to_i - 1]
        else
          answer
        end
      rescue Timeout::Error, Interrupt
        nil
      end
    end
  end
end
