# frozen_string_literal: true

require "json"
require_relative "../shell_session"
require_relative "../process_registry"

module HermesTools
  # terminal — execute shell commands with persistent state (cwd + exported
  # env survive across calls via Hermes::ShellSession). Port of hermes-agent
  # tools/terminal_tool.py (local backend).
  class Terminal < Brute::Tool
    description "Execute shell commands. Filesystem, current working directory, and exported " \
                "environment variables persist between calls. Use background=true for " \
                "long-running commands (returns a session_id for the process tool)."
    params({
      "type" => "object",
      "properties" => {
        "command" => { "type" => "string", "description" => "The command to execute" },
        "background" => { "type" => "boolean", "description" => "Run in the background, returning a session_id (default false).", "default" => false },
        "timeout" => { "type" => "integer", "description" => "Max seconds to wait (default: 180, foreground max: 600). Use background=true for longer commands.", "minimum" => 1 },
        "workdir" => { "type" => "string", "description" => "Working directory for this command (absolute path). Defaults to the session working directory." },
        "notify_on_complete" => { "type" => "boolean", "description" => "With background=true: emit one notification event when the process exits.", "default" => false },
      },
      "required" => ["command"],
    })

    def initialize(session: nil, registry: nil)
      @session = session
      @registry = registry
    end

    attr_writer :registry

    def name = "terminal"

    def execute(command:, background: false, timeout: Hermes::ShellSession::DEFAULT_TIMEOUT,
                workdir: nil, notify_on_complete: false, **_rest)
      return err("command is required") if command.to_s.strip.empty?

      if background
        entry = registry.spawn(command, workdir: workdir || session.cwd, notify: notify_on_complete)
        return JSON.dump(
          "session_id" => entry.session_id, "pid" => entry.pid, "exit_code" => 0,
          "status" => "running",
          "note" => notify_on_complete ? "Completion notification armed." : "Running in background. Use the process tool to poll/log/wait/kill.",
        )
      end

      if timeout > Hermes::ShellSession::FOREGROUND_MAX_TIMEOUT
        return err("Foreground timeout above #{Hermes::ShellSession::FOREGROUND_MAX_TIMEOUT}s is rejected; use background=true for longer commands.")
      end

      result = session.exec(command, cwd: workdir, timeout: timeout)
      JSON.dump(
        "output" => result[:output],
        "exit_code" => result[:exit_code],
        "cwd" => result[:cwd],
        "status" => result[:exit_code].zero? ? "ok" : (result[:exit_code] == 124 ? "timeout" : "error"),
      )
    rescue StandardError => e
      err("#{e.class}: #{e.message}")
    end

    private

    def session
      @session ||= Hermes::ShellSession.new
    end

    def registry
      @registry ||= Hermes::ProcessRegistry.new
    end

    def err(message)
      JSON.dump("error" => message)
    end
  end
end
