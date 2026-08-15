# frozen_string_literal: true

require "json"
require_relative "../process_registry"

module HermesTools
  # process — manage background processes spawned by terminal(background=true).
  # Port of hermes-agent tools/process_registry.py's agent-facing tool.
  class Process < Brute::Tool
    description "Manage background processes: list, poll, log, wait, kill, write, submit, close stdin."
    params({
      "type" => "object",
      "properties" => {
        "action" => { "type" => "string", "enum" => %w[list poll log wait kill write submit close] },
        "session_id" => { "type" => "string", "description" => "The background process session id." },
        "data" => { "type" => "string", "description" => "Data for write/submit (stdin)." },
        "timeout" => { "type" => "integer", "description" => "For wait: max seconds (default 60)." },
        "tail" => { "type" => "integer", "description" => "For log: only the last N lines." },
      },
      "required" => ["action"],
    })

    def initialize(registry: nil)
      @registry = registry
    end

    def name = "process"

    def execute(action:, session_id: nil, data: nil, timeout: 60, tail: nil, **_rest)
      case action
      when "list"
        JSON.dump("processes" => registry.list)
      when "poll"
        with_entry(session_id) { |e| JSON.dump(registry.poll(session_id)) }
      when "log"
        content = registry.log(session_id, tail: tail)
        return err("unknown session_id '#{session_id}'") if content.nil?

        JSON.dump("session_id" => session_id, "log" => content)
      when "wait"
        result = registry.wait_for(session_id, timeout: timeout)
        return err("unknown session_id '#{session_id}'") if result.nil?

        JSON.dump(result)
      when "kill"
        ok = registry.kill(session_id)
        JSON.dump("session_id" => session_id, "killed" => !!ok)
      when "write"
        return err("data is required for write") if data.nil?

        JSON.dump("session_id" => session_id, "written" => !!registry.write_stdin(session_id, data))
      when "submit"
        return err("data is required for submit") if data.nil?

        JSON.dump("session_id" => session_id, "submitted" => !!registry.submit_stdin(session_id, data))
      when "close"
        JSON.dump("session_id" => session_id, "closed" => !!registry.close_stdin(session_id))
      else
        err("unknown action '#{action}'. Use: list, poll, log, wait, kill, write, submit, close")
      end
    end

    private

    def registry
      @registry ||= Hermes::ProcessRegistry.new
    end

    def with_entry(session_id)
      return err("session_id is required") if session_id.to_s.empty?
      return err("unknown session_id '#{session_id}'") unless registry.get(session_id)

      yield
    end

    def err(message)
      JSON.dump("error" => message)
    end
  end
end
