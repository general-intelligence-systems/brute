# frozen_string_literal: true

# OpenFang's inter-agent tools (agent_send / agent_spawn / agent_list /
# agent_kill), ported from RightNow-AI/openfang
# crates/openfang-runtime/src/tool_runner.rs — tool names, descriptions,
# parameter schemas, and result strings are verbatim.
#
# The openfang kernel's agent table becomes an in-process Registry:
# agent_spawn parses the same agent.toml manifest shape openfang agents ship
# with (a small TOML subset — scalars, """multiline strings""", string
# arrays, [sections]) and builds a Brute::Agent whose capabilities.tools
# resolve through OpenFang::TOOL_MAP. Delegation in brute is just "an agent
# is a tool" (Brute::Tools::SubAgent is the library-level version of the
# same idea).
#
# Mirrors openfang's MAX_AGENT_CALL_DEPTH = 5 guard against runaway
# A->B->C delegation chains.

require "bundler/setup"
require "brute"

require "securerandom"

module OpenFang
  module Tools
    MAX_AGENT_CALL_DEPTH = 5
    DEFAULT_MODEL = ENV.fetch("OPENFANG_MODEL", "claude-sonnet-4-20250514")

    # In-process stand-in for the openfang kernel's agent table. Each entry
    # keeps a persistent session so a spawned agent retains its own history
    # across agent_send calls, like a running openfang agent would.
    module Registry
      Entry = Struct.new(:id, :name, :state, :provider_name, :model, :agent, :session, keyword_init: true)

      @agents = {}
      @mutex = Mutex.new

      class << self
        def register(entry)
          @mutex.synchronize { @agents[entry.id] = entry }
        end

        def find(id_or_name)
          @mutex.synchronize do
            @agents[id_or_name] || @agents.values.find { |e| e.name == id_or_name }
          end
        end

        def remove(id_or_name)
          entry = find(id_or_name)
          @mutex.synchronize { @agents.delete(entry.id) } if entry
          entry
        end

        def all
          @mutex.synchronize { @agents.values }
        end

        def clear
          @mutex.synchronize { @agents.clear }
        end
      end
    end

    # Minimal parser for the TOML subset used by openfang agent manifests:
    # `key = value` scalars (strings, numbers, booleans), `"""multiline
    # strings"""`, single-line or multiline string arrays, and [section] /
    # [[table]] headers. Returns a flat hash with dotted keys
    # ("model.system_prompt", "capabilities.tools", ...).
    module Manifest
      def self.parse(toml)
        result = {}
        section = nil
        lines = toml.lines

        i = 0
        while i < lines.length
          line = lines[i].strip
          i += 1

          next if line.empty? || line.start_with?("#")

          if (m = line.match(/\A\[\[?([^\]]+)\]\]?\z/))
            section = m[1].strip
            next
          end

          m = line.match(/\A([A-Za-z0-9_.-]+)\s*=\s*(.*)\z/m) or next
          key = section ? "#{section}.#{m[1]}" : m[1]
          rest = m[2]

          if rest.start_with?('"""')
            value, i = parse_multiline_string(rest[3..], lines, i)
          elsif rest.start_with?("[")
            value, i = parse_array(rest, lines, i)
          else
            value = parse_scalar(rest)
          end

          result[key] = value unless value.nil?
        end

        result
      end

      def self.parse_multiline_string(rest, lines, i)
        if (close = rest.index('"""'))
          return [unescape(rest[...close]), i]
        end

        # TOML trims the newline immediately after the opening delimiter.
        buffer = rest.empty? || rest == "\n" ? +"" : +rest
        while i < lines.length
          line = lines[i]
          i += 1
          if (close = line.index('"""'))
            buffer << line[...close]
            return [unescape(buffer), i]
          end
          buffer << line
        end
        [unescape(buffer), i]
      end

      def self.parse_array(rest, lines, i)
        buffer = +rest
        until balanced?(buffer) || i >= lines.length
          buffer << lines[i]
          i += 1
        end
        [buffer.scan(/"((?:[^"\\]|\\.)*)"/).map { |(s)| unescape(s) }, i]
      end

      def self.balanced?(buffer)
        depth = 0
        in_string = false
        buffer.each_char.with_index do |ch, idx|
          case ch
          when '"' then in_string = !in_string unless buffer[idx - 1] == "\\"
          when "[" then depth += 1 unless in_string
          when "]" then depth -= 1 unless in_string
          end
        end
        depth <= 0
      end

      def self.parse_scalar(rest)
        case rest
        when /\A"((?:[^"\\]|\\.)*)"/ then unescape(Regexp.last_match(1))
        when /\A(true|false)\b/      then Regexp.last_match(1) == "true"
        when /\A(-?\d+\.\d+)/        then Regexp.last_match(1).to_f
        when /\A(-?\d+)/             then Regexp.last_match(1).to_i
        end
      end

      def self.unescape(string)
        string.gsub(/\\(["\\nrt])/) do
          { '"' => '"', "\\" => "\\", "n" => "\n", "r" => "\r", "t" => "\t" }[Regexp.last_match(1)]
        end
      end
    end

    # Builds the same middleware stack the ported agent examples use, from a
    # parsed manifest. Shared by AgentSpawn (and reusable from example code).
    module SpawnedAgent
      def self.build(manifest)
        prompt = manifest["model.system_prompt"] || manifest["system_prompt"]
        temperature = (manifest["model.temperature"] || 0.7).to_f
        tools = OpenFang.tools(Array(manifest["capabilities.tools"]))

        system_prompt = prompt && Brute::SystemPrompt.build { |p, _ctx| p << prompt }

        agent = Brute::Agent.new(
          provider: Brute.provider,
          model:    resolve_model(manifest),
          tools:    tools,
        ) do
          use Brute::Middleware::SystemPrompt, system_prompt: system_prompt if system_prompt
          use Brute::Middleware::ToolResultLoop
          use Brute::Middleware::MaxIterations, max_iterations: 25
          use Brute::Middleware::ToolCall
          run Brute::Middleware::Completion::RubyLLM.new(temperature: temperature)
        end

        [agent, resolve_model(manifest)]
      end

      def self.resolve_model(manifest)
        model = manifest["model.model"].to_s
        model.empty? || model == "default" ? DEFAULT_MODEL : model
      end
    end

    class AgentSpawn < RubyLLM::Tool
      description "Spawn a new agent from a TOML manifest. Returns the new agent's ID and name."

      param :manifest_toml, type: 'string', desc: "The agent manifest in TOML format (must include name, module, [model], and [capabilities])", required: true

      def name; "agent_spawn"; end

      def execute(manifest_toml:)
        manifest = Manifest.parse(manifest_toml)
        agent_name = manifest["name"].to_s
        return "Invalid manifest: missing 'name'" if agent_name.empty?

        agent, model = SpawnedAgent.build(manifest)

        id = SecureRandom.uuid
        Registry.register(Registry::Entry.new(
          id:            id,
          name:          agent_name,
          state:         "Running",
          provider_name: Brute.provider.to_s,
          model:         model,
          agent:         agent,
          session:       Brute::Session.new,
        ))

        "Agent spawned successfully.\n  ID: #{id}\n  Name: #{agent_name}"
      end
    end

    class AgentSend < RubyLLM::Tool
      description "Send a message to another agent and receive their response. Accepts UUID or agent name. Use agent_find first to discover agents."

      param :agent_id, type: 'string', desc: "The target agent's UUID or name", required: true
      param :message, type: 'string', desc: "The message to send to the agent", required: true

      def name; "agent_send"; end

      def execute(agent_id:, message:)
        depth = Thread.current.thread_variable_get(:openfang_agent_call_depth) || 0
        if depth >= MAX_AGENT_CALL_DEPTH
          return "Inter-agent call depth exceeded (max #{MAX_AGENT_CALL_DEPTH}). " \
                 "A->B->C chain is too deep. Use the task queue instead."
        end

        entry = Registry.find(agent_id)
        return "Agent not found: #{agent_id}" unless entry

        Thread.current.thread_variable_set(:openfang_agent_call_depth, depth + 1)
        begin
          entry.session.user(message)
          entry.agent.call(entry.session)
          entry.session.last.content.to_s
        ensure
          Thread.current.thread_variable_set(:openfang_agent_call_depth, depth)
        end
      end
    end

    class AgentList < RubyLLM::Tool
      description "List all currently running agents with their IDs, names, states, and models."

      def name; "agent_list"; end

      def execute
        entries = Registry.all
        return "No agents currently running." if entries.empty?

        output = +"Running agents (#{entries.size}):\n"
        entries.each do |e|
          output << "  - #{e.name} (id: #{e.id}, state: #{e.state}, model: #{e.provider_name}:#{e.model})\n"
        end
        output
      end
    end

    class AgentKill < RubyLLM::Tool
      description "Kill (terminate) another agent by its ID."

      param :agent_id, type: 'string', desc: "The agent's UUID to kill", required: true

      def name; "agent_kill"; end

      def execute(agent_id:)
        entry = Registry.remove(agent_id)
        return "Agent not found: #{agent_id}" unless entry

        "Agent #{agent_id} killed successfully."
      end
    end
  end
end
