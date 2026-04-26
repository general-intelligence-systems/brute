#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "helper"

class TerminalOutput < Brute::Events::Handler
  def <<(event)
    h = event.to_h
    case h[:type]
    when :content          then $stdout.write(h[:data])
    when :reasoning        then $stderr.write(h[:data].to_s.gsub(/^/, "  │ "))
    when :tool_call_start  then puts "\n→ #{h[:data].map { |c| c[:name] }.join(', ')}"
    when :tool_result      then puts "  ✓ #{h[:data][:name]}"
    when :log              then $stderr.puts "[#{h[:data]}]"
    when :error
      d = h[:data]
      if d.is_a?(Hash)
        $stderr.puts "✗ #{d[:error].class}: #{d[:message]}"
        $stderr.puts "  provider: #{d[:provider].inspect}"
        $stderr.puts "  model:    #{d[:model].inspect}"
      else
        # Backward compat for bare exceptions
        $stderr.puts "✗ #{d.class}: #{d.message}"
      end
    when :assistant_complete then puts
    end
    $stdout.flush
    super
  end
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL,
) do
  use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

Brute::Session.new.then do |session|
  session.user("What files are in the current directory? List them.")
  agent.call(session)
end
