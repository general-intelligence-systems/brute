# frozen_string_literal: true

# Shared helpers for Brute examples.
#
# Usage:
#   require_relative "helper"
#
#   agent = Brute::Agent.new(
#     provider: Brute.provider,
#     model:    "claude-sonnet-4-20250514",
#     tools:    Brute::Tools::ALL,
#   ) do
#     use Brute::Middleware::EventHandler, handler_class: TerminalOutput
#     use Brute::Middleware::MaxIterations
#     use Brute::Middleware::SystemPrompt
#     use Brute::Middleware::ToolCall
#     run Brute::Middleware::LLMCall.new
#   end
#
#   Brute::Session.new.then do |session|
#     session.user("Hi")
#     agent.call(session)
#     print_events(session)
#   end

require "pp"
require_relative "../lib/brute"

# Shared event handler that prints streamed events to the terminal.
class TerminalOutput < Brute::Events::Handler
  def <<(event)
    h = event.to_h
    case h[:type]
    when :content          then $stdout.write(h[:data])
    when :reasoning        then $stderr.write(h[:data].to_s.gsub(/^/, "  │ "))
    when :tool_call_start  then puts "\n→ #{h[:data].map { |c| c[:name] }.join(', ')}"
    when :tool_result      then puts "  ✓ #{h[:data][:name]}"
    when :log              then $stderr.puts "[#{h[:data]}]".light_black
    when :error
      d = h[:data]
      if d.is_a?(Hash)
        $stderr.puts "✗ #{d[:error].class}: #{d[:message]}"
        $stderr.puts "  provider: #{d[:provider].inspect}"
        $stderr.puts "  model:    #{d[:model].inspect}"
      else
        $stderr.puts "✗ #{d.class}: #{d.message}"
      end
    when :assistant_complete then puts
    end
    $stdout.flush
    super
  end
end

# Print all session messages in grey using pp formatting.
def print_events(session)
  session.each do |msg|
    puts
    puts msg.pretty_inspect.light_black
  end
end

$stderr.puts Brute::LOGO.light_black
