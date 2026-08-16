# frozen_string_literal: true

require "json"
require_relative "mcp_tool"
require_relative "bm25"

# MCPManager — picoclaw's MCP subsystem (pkg/agent/agent_mcp.go +
# pkg/tools/integration/mcp_tool.go + registry.go's hidden-tool promotion).
#
# Loads servers from tools.mcp.servers (stdio command/args/env, or
# url/headers/type for sse|http|streamable-http), connects lazily via the
# official `mcp` gem, and wraps each discovered tool as an MCPTool.
#
# Deferred/hidden registration: with discovery enabled (or a server's
# `deferred: true`), tools register HIDDEN — not advertised and not callable
# until a discovery tool promotes them for `ttl` turns (tick once per turn).
class MCPManager
  Entry = Struct.new(:name, :description, :schema, :server_name, :tool_name, :hidden, :client)

  attr_reader :media_store

  def initialize(config:, workspace: Dir.pwd, media_store: nil)
    @config = config || {}
    @workspace = workspace
    @media_store = media_store
    @discovery = @config["discovery"] || {}
    @entries = {}
    @promoted = {}
    @clients = {}
  end

  def servers = @config["servers"] || {}
  def discovery_enabled? = @discovery.fetch("enabled", false)
  def ttl = @discovery["ttl"] || 5
  def max_search_results = @discovery["max_search_results"] || 5

  # Connect every enabled server and register its tools. Failures are
  # logged and skipped (upstream keeps the agent up when a server is down).
  def start
    require "mcp"

    servers.each do |name, scfg|
      next unless scfg.fetch("enabled", true)

      begin
        client = connect(name, scfg)
        client.connect
        @clients[name] = client
        client.tools.each do |tool|
          full_name = MCPTool.full_name(name, tool.name)
          hidden = scfg.key?("deferred") ? scfg["deferred"] : discovery_enabled?
          @entries[full_name] = Entry.new(full_name, tool.description, tool.input_schema,
                                          name, tool.name, hidden, client)
        end
      rescue StandardError, LoadError => e
        warn "mcp: server #{name.inspect} failed: #{e.message} — skipped"
      end
    end
    self
  end

  def stop
    @clients.each_value { |c| c.close rescue nil }
  end

  def tools
    @entries.values.map { |entry| MCPTool.new(manager: self, server_name: entry.server_name,
                                              tool_name: entry.tool_name,
                                              tool_description: entry.description.to_s,
                                              schema: entry.schema || {}) }
  end

  def entry(name) = @entries[name]

  def locked?(name)
    entry = @entries[name]
    entry && entry.hidden && !@promoted.key?(name)
  end

  # Visible tool defs for the advertised list: non-hidden + promoted.
  def visible_entries
    @entries.values.reject { |e| locked?(e.name) }
  end

  def hidden_entries
    @entries.values.select { |e| locked?(e.name) }
  end

  def promote!(names)
    names.each { |name| @promoted[name] = ttl if @entries.key?(name) }
  end

  # TickTTL port: one decrement per turn; expired promotions drop out.
  def tick!
    @promoted = @promoted.filter_map do |name, remaining|
      [name, remaining - 1] if remaining > 1
    end.to_h
  end

  def call(server_name, tool_name, args)
    client = @clients[server_name]
    raise "MCP server #{server_name.inspect} is not connected" unless client

    client.call_tool(name: tool_name, arguments: args)
  end

  def search_regex(pattern, max_results)
    regex = Regexp.new(pattern, Regexp::IGNORECASE)
    hidden_entries.sort_by(&:name).filter_map do |entry|
      next unless regex.match?(entry.name) || regex.match?(entry.description.to_s)

      { name: entry.name, description: entry.description.to_s }
    end.first(max_results)
  end

  def search_bm25(query, max_results)
    docs = hidden_entries.sort_by(&:name).map { |e| { name: e.name, description: e.description.to_s } }
    return [] if docs.empty?

    engine = BM25::Engine.new(docs.map { |d| [d, "#{d[:name]} #{d[:description]}"] })
    engine.search(query, max_results).map(&:first)
  end

  private

  def connect(name, scfg)
    transport =
      if scfg["command"]
        MCP::Client::Stdio.new(command: scfg["command"], args: Array(scfg["args"]), env: load_env(scfg))
      elsif scfg["url"]
        MCP::Client::HTTP.new(url: scfg["url"], headers: scfg["headers"] || {})
      else
        raise "MCP server #{name.inspect} needs command or url"
      end
    MCP::Client.new(transport: transport)
  end

  def load_env(scfg)
    env = (scfg["env"] || {}).transform_keys(&:to_s)
    if (file = scfg["env_file"].to_s) != ""
      File.foreach(File.expand_path(file)) do |line|
        key, value = line.strip.split("=", 2)
        env[key] = value if key && !key.empty? && value
      end
    end
    env
  end
end
