# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "time"
require "uri"

module PrimeAgent
  # The port of prime-agent's rlm/mcp_base.py (McpIntegration): a hosted MCP
  # server as a kernel-callable integration. The protocol client is the
  # official Ruby SDK (`mcp` gem, MCP::Client::HTTP over streamable HTTP,
  # required lazily); credentials live in the SAME auth.json prime-agent
  # uses (~/.prime/agent/auth.json, key "mcp:<server>"), so one login serves
  # both. Behavior parity notes:
  #
  #  - a static bearer-token env var wins (upstream's isAuthed order);
  #  - api_key credentials may name an env var holding the key; "!command"
  #    refs are skipped;
  #  - OAuth access tokens are honored until expires - 30s skew, then
  #    refreshed (kernel-side: POST to the stored token endpoint, auth.json
  #    rewritten under flock — upstream routes this through the host bridge;
  #    the shared file makes it safe here);
  #  - call_tool opens a FRESH client per call (robust to idle sessions and
  #    token rotation, same as upstream);
  #  - results prefer structuredContent, then joined text blocks, then raw
  #    content blocks; isError raises McpToolError.
  module Mcp
    EXPIRY_SKEW_SECONDS = 30 # _EXPIRY_SKEW_SECONDS

    BUILTIN_CATALOG = {
      "linear" => "https://mcp.linear.app/mcp",
      "notion" => "https://mcp.notion.com/mcp",
    }.freeze

    class NotEnabled < StandardError
      def initialize(server)
        super(
          "The '#{server}' integration is not enabled: no credentials found. " \
          "Tell the user to run `ruby mcp_login.rb #{server}` from the prime-agent example " \
          "to connect it. Do not ask them to set environment variables.",
        )
      end
    end

    class McpToolError < StandardError; end

    # One integration instance per server. Skills wrap this (linear/notion).
    class Integration
      attr_reader :server, :url

      def initialize(server:, url: nil, bearer_token_env: nil, transport_factory: nil, client_factory: nil)
        raise ArgumentError, "server must be non-empty" if server.to_s.empty?

        @server = server
        @url = url || BUILTIN_CATALOG[server]
        raise ArgumentError, "no MCP URL known for #{server.inspect}" if @url.nil?
        @bearer_token_env = bearer_token_env
        @transport_factory = transport_factory # default MCP::Client::HTTP
        @client_factory = client_factory       # test seam
        @tools = nil
        @tools_mutex = Mutex.new
      end

      # tools/list, memoized per process (upstream caches on first use).
      def list_tools
        @tools_mutex.synchronize do
          @tools ||= with_client { |client| client.tools }.map do |tool|
            # MCP::Client::Tool exposes attr_readers (name/description/
            # input_schema); the spec-side FakeClient returns hashes.
            if tool.is_a?(Hash)
              hash = tool
            else
              schema = tool.respond_to?(:input_schema) ? tool.input_schema : nil
              schema = schema.to_h if schema.respond_to?(:to_h)
              hash = { "name" => tool.name, "description" => tool.description, "inputSchema" => schema }
            end
            {
              "name" => hash["name"],
              "description" => hash["description"].to_s,
              "inputSchema" => hash["inputSchema"] || {},
            }
          end
        end
      end

      # tools/call — a fresh client per call. The gem's client returns the
      # full JSON-RPC response hash; the tool result lives under "result".
      def call_tool(tool, **arguments)
        response = with_client do |client|
          client.call_tool(name: tool.to_s, arguments: arguments.transform_keys(&:to_s))
        end
        parse_result(response["result"] || {})
      end

      private

      # client_factory is the test seam (specs inject a duck-typed client and
      # never touch the gem); the default builds MCP::Client over streamable
      # HTTP with the bearer credential.
      def with_client
        client = (@client_factory || method(:default_client)).call
        yield client
      ensure
        client.close if client.respond_to?(:close)
      end

      def default_client
        require "mcp" # the example bundle's gem; lazily, so kernels boot without it
        transport = (@transport_factory || method(:default_transport)).call
        client = MCP::Client.new(transport: transport)
        client.connect
        client
      end

      def default_transport
        MCP::Client::HTTP.new(url: @url, headers: { "Authorization" => "Bearer #{resolve_token}" })
      end

      # -- credentials (mcp_base.py _token/_resolve_token) -----------------

      def provider_id
        "mcp:#{@server}"
      end

      def current_token
        if @bearer_token_env
          env_token = ENV[@bearer_token_env].to_s.strip
          return env_token unless env_token.empty?
        end
        cred = Mcp.read_auth(provider_id)
        return nil if cred.nil?

        if cred["type"] == "api_key"
          key = Mcp.resolve_config_value(cred["key"].to_s)
          return key.empty? ? nil : key
        end

        access = cred["access"].to_s
        expires = cred["expires"]
        fresh = expires.is_a?(Numeric) &&
                (Time.now.to_f * 1000) < (expires - EXPIRY_SKEW_SECONDS * 1000)
        return access unless access.empty? || !fresh

        nil # needs refresh
      end

      def resolve_token
        token = current_token
        return token if token

        unless Mcp.read_auth(provider_id).nil?
          refresh_error = nil
          begin
            Mcp.refresh_credentials(@server, provider_id: provider_id)
          rescue StandardError => error
            refresh_error = error
          end
          token = current_token
          return token if token
          raise "Failed to refresh credentials for '#{@server}': #{refresh_error.message}" if refresh_error
        end
        raise NotEnabled, @server
      end

      # _parse_result: structuredContent > joined text blocks > raw blocks;
      # isError raises McpToolError.
      def parse_result(result)
        content = result["content"] || []
        texts = content.filter_map { |block| block["text"] }
        if result["isError"]
          raise McpToolError, texts.empty? ? "MCP tool returned an error" : texts.join("\n")
        end

        structured = result["structuredContent"]
        return structured unless structured.nil?
        return texts.join("\n") unless texts.empty?

        content.empty? ? result : content
      end
    end

    # ------------------------------------------------------------------
    # auth.json — shared with prime-agent (~/.prime/agent/auth.json)
    # ------------------------------------------------------------------

    module_function

    def agent_dir
      raw = ENV["PRIME_AGENT_CODING_AGENT_DIR"] || ENV["PI_CODING_AGENT_DIR"] || "~/.prime/agent"
      File.expand_path(raw)
    end

    def auth_path
      File.join(agent_dir, "auth.json")
    end

    def read_auth(provider_id)
      auth = read_auth_file
      cred = auth[provider_id]
      cred.is_a?(Hash) ? cred : nil
    end

    def write_auth(provider_id, credential)
      FileUtils.mkdir_p(agent_dir)
      File.open(auth_path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        auth =
          begin
            file.rewind
            data = JSON.parse(file.read)
            data.is_a?(Hash) ? data : {}
          rescue JSON::ParserError
            {}
          end
        auth[provider_id] = credential
        tmp = "#{auth_path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(auth)}\n")
        File.rename(tmp, auth_path)
      end
      credential
    end

    def read_auth_file
      return {} unless File.exist?(auth_path)

      data = JSON.parse(File.read(auth_path))
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end

    # Stored api_key values may be a literal or an env-var name; "!command"
    # refs can't be run safely from the kernel, so skip them (upstream's rule).
    def resolve_config_value(value)
      value = value.to_s.strip
      return "" if value.empty? || value.start_with?("!")

      (ENV[value] || value).strip
    end

    # Refresh an OAuth credential: POST the refresh token to the stored token
    # endpoint, rewrite auth.json, keep the prior refresh token when the
    # server omits a new one (upstream's refreshToken).
    # `http_post` is the test seam: (uri, form_hash) -> response-like.
    # endpoint, rewrite auth.json, keep the prior refresh token when the
    # server omits a new one (upstream's refreshToken).
    def refresh_credentials(server, provider_id: "mcp:#{server}", http_post: nil)
      cred = read_auth(provider_id)
      raise "no credentials stored for #{provider_id}" if cred.nil?

      refresh_token = cred["refresh"].to_s
      raise "no refresh token stored for #{provider_id}" if refresh_token.empty?

      endpoint = cred["tokenEndpoint"].to_s
      raise "no token endpoint stored for #{provider_id}" if endpoint.empty?

      body = { "grant_type" => "refresh_token", "refresh_token" => refresh_token }
      body["client_id"] = cred["clientId"] unless cred["clientId"].to_s.empty?
      post = http_post || ->(uri, form) { Net::HTTP.post_form(uri, form) }
      response = post.call(URI(endpoint), body)
      unless response.is_a?(Net::HTTPSuccess)
        raise "token refresh failed (#{response.code}): #{response.body}"
      end

      data = JSON.parse(response.body)
      access = data["access_token"].to_s
      raise "token refresh returned no access_token" if access.empty?

      expires_in = data["expires_in"] || 3600
      write_auth(provider_id, cred.merge(
        "access" => access,
        "refresh" => data["refresh_token"].to_s.empty? ? refresh_token : data["refresh_token"],
        "expires" => (Time.now.to_f * 1000 + expires_in * 1000).round,
      ))
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/mcp" do
  M = PrimeAgent::Mcp

  # A duck-typed MCP::Client stand-in: the gem only loads in the example
  # bundle, so specs drive Integration through this instead.
  class FakeClient
    def initialize(results)
      @results = results
    end

    def tools
      @results["tools/list"]["tools"] || []
    end

    def call_tool(name:, arguments:)
      { "result" => @results.fetch("tools/call") }
    end

    def close
      nil
    end
  end

  def with_auth_dir(dir)
    previous = ENV["PRIME_AGENT_CODING_AGENT_DIR"]
    ENV["PRIME_AGENT_CODING_AGENT_DIR"] = dir
    yield
  ensure
    previous ? ENV["PRIME_AGENT_CODING_AGENT_DIR"] = previous : ENV.delete("PRIME_AGENT_CODING_AGENT_DIR")
  end

  def integration(dir, results: {}, **opts)
    M::Integration.new(server: "linear", client_factory: -> { FakeClient.new(results) }, **opts)
  end

  it "resolves config values: literal, env-name indirection, skipped command refs" do
    M.resolve_config_value("literal-key").should == "literal-key"
    ENV["MCP_SPEC_KEY"] = "from-env"
    M.resolve_config_value("MCP_SPEC_KEY").should == "from-env"
    M.resolve_config_value("!echo secret").should == ""
    M.resolve_config_value("  ").should == ""
  end

  it "round-trips credentials through the shared auth.json" do
    Dir.mktmpdir do |dir|
      with_auth_dir(dir) do
        M.write_auth("mcp:linear", { "type" => "api_key", "key" => "lk_123" })
        M.read_auth("mcp:linear").should == { "type" => "api_key", "key" => "lk_123" }
        M.read_auth("mcp:notion").should.be.nil
        JSON.parse(File.read(M.auth_path))["mcp:linear"]["key"].should == "lk_123"
      end
    end
  end

  it "resolves tokens: env bearer wins, api_key indirection, oauth freshness with skew" do
    Dir.mktmpdir do |dir|
      with_auth_dir(dir) do
        M.write_auth("mcp:linear", { "type" => "api_key", "key" => "MCP_SPEC_KEY" })
        ENV["MCP_SPEC_KEY"] = "resolved-key"
        integration(dir).send(:current_token).should == "resolved-key"

        ENV["MCP_BEARER"] = "env-wins"
        integration(dir, bearer_token_env: "MCP_BEARER").send(:current_token).should == "env-wins"

        M.write_auth("mcp:linear", { "type" => "oauth", "access" => "fresh-token",
                                     "expires" => (Time.now.to_f * 1000 + 60_000).round })
        integration(dir).send(:current_token).should == "fresh-token"

        M.write_auth("mcp:linear", { "type" => "oauth", "access" => "stale-token",
                                     "expires" => (Time.now.to_f * 1000 + 10_000).round }) # inside the 30s skew
        integration(dir).send(:current_token).should.be.nil
      end
    end
  end

  it "raises NotEnabled with login instructions when nothing is stored" do
    Dir.mktmpdir do |dir|
      with_auth_dir(dir) do
        error = lambda { integration(dir).send(:resolve_token) }.should.raise(M::NotEnabled)
        error.message.should.include "not enabled"
        error.message.should.include "mcp_login.rb linear"
      end
    end
  end

  it "refreshes expired oauth credentials into auth.json, keeping an omitted refresh token" do
    Dir.mktmpdir do |dir|
      with_auth_dir(dir) do
        M.write_auth("mcp:linear", {
          "type" => "oauth", "access" => "old", "refresh" => "keep-me",
          "expires" => (Time.now.to_f * 1000).round - 1000,
          "tokenEndpoint" => "https://auth.example/token", "clientId" => "cid",
        })
        posted = nil
        post = lambda do |uri, form|
          posted = [uri.to_s, form]
          body = JSON.generate("access_token" => "new-token", "expires_in" => 3600)
          Struct.new(:code, :body) do
            def is_a?(klass) = klass == Net::HTTPSuccess || super
          end.new("200", body)
        end
        M.refresh_credentials("linear", http_post: post)
        posted[0].should == "https://auth.example/token"
        posted[1]["grant_type"].should == "refresh_token"
        posted[1]["refresh_token"].should == "keep-me"
        posted[1]["client_id"].should == "cid"
        cred = M.read_auth("mcp:linear")
        cred["access"].should == "new-token"
        cred["refresh"].should == "keep-me" # server omitted a new one
        integration(dir).send(:current_token).should == "new-token"
      end
    end
  end

  it "lists tools and calls them through the MCP client, parsing results upstream-style" do
    Dir.mktmpdir do |dir|
      with_auth_dir(dir) do
        M.write_auth("mcp:linear", { "type" => "api_key", "key" => "k" })
        results = {
          "tools/list" => { "tools" => [{ "name" => "search", "description" => "Search issues", "inputSchema" => { "type" => "object" } }] },
          "tools/call" => { "content" => [{ "type" => "text", "text" => "found 3" }], "isError" => false },
        }
        integration = integration(dir, results: results)
        tools = integration.list_tools
        tools.first["name"].should == "search"
        tools.first["description"].should == "Search issues"
        integration.call_tool("search", query: "bug").should == "found 3"
      end
    end
  end

  it "prefers structuredContent and raises McpToolError on isError" do
    Dir.mktmpdir do |dir|
      with_auth_dir(dir) do
        M.write_auth("mcp:linear", { "type" => "api_key", "key" => "k" })
        structured = integration(dir, results: {
          "tools/call" => { "structuredContent" => { "count" => 3 },
                            "content" => [{ "type" => "text", "text" => "ignored" }] },
        })
        structured.call_tool("count").should == { "count" => 3 }

        failing = integration(dir, results: {
          "tools/call" => { "isError" => true,
                            "content" => [{ "type" => "text", "text" => "nope" }] },
        })
        lambda { failing.call_tool("count") }.should.raise(M::McpToolError)
      end
    end
  end
end
