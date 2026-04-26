# frozen_string_literal: true

require 'bundler/setup'
require 'brute'

module Brute
  module Events
    # EXAMPLES:
    # class TerminalOutput < Brute::Events::Handler
    #   def <<(event)
    #     h = event.to_h
    #     case h[:type]
    #     when :content       then write(h[:data])
    #     when :tool_result   then write("  ✓ #{h[:data][:name]}\n")
    #     when :log           then write("[#{h[:data]}]\n")
    #     end
    #     super  # forward to whatever's wrapped underneath
    #   end
    # 
    #   private
    #   def write(text); $stderr.write(text); $stderr.flush; end
    # end
    # 
    # class JsonlTrace < Brute::Events::Handler
    #   def initialize(inner, path:)
    #     super(inner)
    #     @file = File.open(path, "a")
    #   end
    # 
    #   def <<(event)
    #     @file.puts(JSON.generate(event.to_h))
    #     @file.flush
    #     super
    #   end
    # end
    # 
    # class FilterNoise < Brute::Events::Handler
    #   # Drop reasoning chunks before they reach the terminal
    #   def <<(event)
    #     return self if event.to_h[:type] == :reasoning
    #     super
    #   end
    # end
    #
    # pipeline = Brute::Pipeline.new do
    #   use Brute::Middleware::EventHandler, handler_class: JsonlTrace, path: "trace.jsonl"
    #   use Brute::Middleware::EventHandler, handler_class: FilterNoise
    #   use Brute::Middleware::EventHandler, handler_class: TerminalOutput
    # end
    #
    class Handler
      def initialize(inner)
        @inner = inner
      end

      # Default: pass through. Subclasses override <<, do their thing,
      # then super (or don't, to swallow the event).
      def <<(event)
        tap do
          @inner << event if @inner
        end
      end
    end
  end
end

test do
  # not implemented
end
