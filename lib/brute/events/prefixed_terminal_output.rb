# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Events
    # TerminalOutput variant that prefixes all output with a label.
    # Useful for sub-agents running concurrently — the prefix makes it
    # clear which agent produced each line.
    #
    # Usage in a middleware stack:
    #
    #   use Brute::Middleware::EventHandler,
    #       handler_class: Brute::Events::PrefixedTerminalOutput,
    #       prefix: "explore"
    #
    class PrefixedTerminalOutput < Brute::Events::Handler
      def initialize(inner, prefix: "sub-agent")
        super(inner)
        @prefix = prefix
        @tag = "[#{@prefix}]".light_black
      end

      def <<(event)
        $stdout.sync = true

        type = event.to_h[:type]
        data = event.to_h[:data]

        method = "on_#{type}"
        send(method, data) if respond_to?(method, true)

        super
      end

      private

        def on_content(data)
          # Prefix each line so interleaved output is distinguishable
          data.to_s.each_line { |line| $stdout.write("#{@tag} #{line}") }
        end

        def on_tool_call_start(data)
          data.each do |tool_call|
            puts "#{@tag} [tool] #{tool_call[:name]} - #{tool_call[:arguments]}"
          end
        end

        def on_tool_result(data)
          puts "#{@tag} [tool] #{data[:name]} - done"
        end

        def on_log(data)
          $stderr.puts "#{@tag} #{data}".light_black
        end

        def on_error(data)
          if data.is_a?(Hash)
            $stderr.puts "#{@tag} error: #{data[:message]}"
          else
            $stderr.puts "#{@tag} error: #{data}"
          end
        end
    end
  end
end

test do
  # not implemented
end
