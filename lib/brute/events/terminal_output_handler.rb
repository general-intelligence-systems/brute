# frozen_string_literal: true

require 'bundler/setup'
require 'brute'


module Brute
  module Events
    class TerminalOutput < Brute::Events::Handler
      def <<(event)
        $stdout.sync = true

        type = event.to_h[:type]
        data = event.to_h[:data]

        method = "on_#{type}"

        if respond_to?(method, true)
          send(method, data) 
        end

        super
      end

      private

        def on_content(data)
          $stdout.write(data)
        end

        def on_reasoning(data)
          $stderr.write(data.to_s.gsub(/^/, "  │ "))
        end

        def on_tool_call_start(data)
          puts
          data.each do |tool_call|
            puts "[tool] #{tool_call[:name]} - #{tool_call[:arguments]}"
          end
        end

        def on_tool_result(data)
          puts "[tool] #{data[:name]} - done"
        end

        def on_log(data)
          $stderr.puts "#{data}".light_black
        end

        def on_assistant_complete(_)
          puts
        end

        def on_error(data)
          if data.is_a?(Hash)
            $stderr.puts "✗ #{data[:error].class}: #{data[:message]}"
            $stderr.puts "  provider: #{data[:provider].inspect}"
            $stderr.puts "  model:    #{data[:model].inspect}"
          else
            $stderr.puts "✗ #{data.class}: #{data.message}"
          end
        end
    end
  end
end

test do
  # not implemented
end
