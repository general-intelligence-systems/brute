# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "socket"
require "uri"

require_relative "mcp"

module PrimeAgent
  # McpOAuth — OAuth 2.1 for hosted MCP servers, the port of prime-agent's
  # packages/ai/src/mcp/oauth.ts: discovery (authorization-server metadata,
  # openid-configuration fallback), RFC 7591 dynamic client registration,
  # PKCE S256 with an independent state, a localhost callback race against a
  # manual paste, and token exchange into the shared auth.json.
  #
  # This is a HOST-side helper (run via mcp_login.rb) — the kernel only reads
  # the resulting credential.
  module McpOAuth
    CALLBACK_HOST = "127.0.0.1"   # PI_OAUTH_CALLBACK_HOST default
    CALLBACK_PORTS = (53_700..53_709).to_a # PI_MCP_OAUTH_CALLBACK_PORT + 10 candidates
    CALLBACK_PATH = "/callback"
    TOKEN_EXPIRY_BUFFER_MS = 5 * 60 * 1000

    module_function

    # Full flow: discover -> register -> authorize -> exchange -> store.
    # `announce` receives the URL to open (puts by default); `prompt` reads a
    # manually pasted redirect URL (gets by default). Returns the credential.
    def login(server, url: Mcp::BUILTIN_CATALOG[server], label: server.capitalize,
              announce: ->(text) { puts text }, prompt: -> { $stdout.write("paste the redirect URL: "); $stdin.gets })
      raise ArgumentError, "no MCP URL known for #{server.inspect}" if url.nil?

      metadata = discover(url)
      authorization_endpoint = metadata.fetch("authorization_endpoint")
      token_endpoint = metadata.fetch("token_endpoint")
      registration_endpoint = metadata["registration_endpoint"]

      redirect_uris = CALLBACK_PORTS.map { |port| "http://#{CALLBACK_HOST}:#{port}#{CALLBACK_PATH}" }
      client_id = register_client(registration_endpoint, label, redirect_uris) if registration_endpoint

      verifier = random_urlsafe(32)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      state = random_urlsafe(32)

      listener, callback_port = open_callback_listener
      authorize_url = build_authorize_url(
        authorization_endpoint,
        client_id: client_id,
        redirect_uri: "http://#{CALLBACK_HOST}:#{callback_port}#{CALLBACK_PATH}",
        state: state,
        challenge: challenge,
      )
      announce.call("Open this URL to connect #{label}:\n\n#{authorize_url}\n")

      code = await_code(listener, state: state, prompt: prompt)
      credential = exchange_code(
        token_endpoint,
        code: code,
        verifier: verifier,
        client_id: client_id,
        redirect_uri: "http://#{CALLBACK_HOST}:#{callback_port}#{CALLBACK_PATH}",
      )
      Mcp.write_auth("mcp:#{server}", credential)
      credential
    ensure
      listener&.close
    end

    # ------------------------------------------------------------------
    # Steps (each small enough to spec)
    # ------------------------------------------------------------------

    # GET <origin>/.well-known/oauth-authorization-server, falling back to
    # /.well-known/openid-configuration (oauth.ts:67-88).
    def discover(url)
      origin = URI(url).then { |uri| "#{uri.scheme}://#{uri.host}#{uri.port == uri.default_port ? "" : ":#{uri.port}"}" }
      ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"].each do |path|
        metadata = get_json("#{origin}#{path}")
        return metadata if metadata && metadata["authorization_endpoint"] && metadata["token_endpoint"]
      end
      raise "no OAuth metadata discovered for #{url}"
    end

    # RFC 7591 dynamic client registration (oauth.ts:91-108).
    def register_client(registration_endpoint, label, redirect_uris)
      uri = URI(registration_endpoint)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(
        "client_name" => "Prime Agent (#{label})",
        "redirect_uris" => redirect_uris,
        "grant_types" => %w[authorization_code refresh_token],
        "response_types" => %w[code],
        "token_endpoint_auth_method" => "none",
      )
      response = http(uri).request(request)
      unless response.is_a?(Net::HTTPSuccess) || response.code == "201"
        raise "dynamic client registration failed (#{response.code}): #{response.body}"
      end

      client_id = JSON.parse(response.body)["client_id"].to_s
      raise "registration returned no client_id" if client_id.empty?

      client_id
    end

    def build_authorize_url(endpoint, client_id:, redirect_uri:, state:, challenge:)
      params = {
        "response_type" => "code",
        "redirect_uri" => redirect_uri,
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
      }
      params["client_id"] = client_id if client_id
      uri = URI(endpoint)
      uri.query = URI.encode_www_form(params)
      uri.to_s
    end

    def open_callback_listener
      CALLBACK_PORTS.each do |port|
        return [TCPServer.new(CALLBACK_HOST, port), port]
      rescue Errno::EADDRINUSE
        next
      end
      raise "no OAuth callback port free in #{CALLBACK_PORTS.first}-#{CALLBACK_PORTS.last}"
    end

    # Race the browser callback against a manual paste (oauth.ts:286-341).
    def await_code(listener, state:, prompt:)
      channel = Queue.new
      Thread.new do
        begin
          socket = listener.accept
          request_line = socket.gets.to_s
          path = request_line.split(" ")[1].to_s
          params = URI.decode_www_form(URI(path).query.to_s).to_h
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nConnected — you can close this tab.")
          socket.close
          channel << params
        rescue StandardError
          # a malformed hit just doesn't answer
        end
      end
      Thread.new do
        pasted = prompt.call
        params = URI.decode_www_form(URI(pasted.to_s.strip).query.to_s).to_h rescue {}
        channel << params unless params.empty?
      end

      params = channel.pop
      raise "OAuth state mismatch" unless params["state"] == state

      code = params["code"].to_s
      raise "no code in the OAuth callback" if code.empty?

      code
    end

    # Exchange the code; store {access, refresh, expires, tokenEndpoint,
    # clientId} (oauth.ts:231-247, 344-351).
    def exchange_code(token_endpoint, code:, verifier:, client_id:, redirect_uri:)
      body = {
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "code_verifier" => verifier,
      }
      body["client_id"] = client_id if client_id
      uri = URI(token_endpoint)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form(body)
      response = http(uri).request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise "token exchange failed (#{response.code}): #{response.body}"
      end

      data = JSON.parse(response.body)
      access = data["access_token"].to_s
      raise "token exchange returned no access_token" if access.empty?

      expires_in = (data["expires_in"] || 3600).to_i
      {
        "type" => "oauth",
        "access" => access,
        "refresh" => data["refresh_token"],
        "expires" => (Time.now.to_f * 1000 + expires_in * 1000 - TOKEN_EXPIRY_BUFFER_MS).round,
        "tokenEndpoint" => token_endpoint,
        "clientId" => client_id,
      }
    end

    def random_urlsafe(bytes)
      Base64.urlsafe_encode64(SecureRandom.random_bytes(bytes), padding: false)
    end

    def get_json(url)
      uri = URI(url)
      response = http(uri).request(Net::HTTP::Get.new(uri))
      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def http(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |http|
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 20
      end
    end
  end
end

__END__

require "socket"
require "tmpdir"

describe "prime_agent/mcp_oauth" do
  O = PrimeAgent::McpOAuth

  it "builds the authorize URL with PKCE S256 and state" do
    url = O.build_authorize_url(
      "https://auth.example/authorize",
      client_id: "cid", redirect_uri: "http://127.0.0.1:53700/callback",
      state: "state-1", challenge: "ch",
    )
    params = URI.decode_www_form(URI(url).query).to_h
    params["response_type"].should == "code"
    params["client_id"].should == "cid"
    params["redirect_uri"].should == "http://127.0.0.1:53700/callback"
    params["state"].should == "state-1"
    params["code_challenge"].should == "ch"
    params["code_challenge_method"].should == "S256"
  end

  it "await_code returns the pasted code and rejects state mismatches" do
    listener = TCPServer.new("127.0.0.1", 0)
    pasted = -> { "http://127.0.0.1:53700/callback?code=abc123&state=s1" }
    O.await_code(listener, state: "s1", prompt: pasted).should == "abc123"
    lambda { O.await_code(listener, state: "s2", prompt: pasted) }.should.raise(RuntimeError)
  ensure
    listener.close
  end

  it "exchange_code posts the PKCE verifier and stores the upstream credential shape" do
    Dir.mktmpdir do |dir|
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      captured = nil
      Thread.new do
        socket = server.accept
        headers = {}
        request_line = socket.gets
        while (line = socket.gets) && line != "\r\n"
          key, value = line.split(": ", 2)
          headers[key] = value
        end
        captured = [request_line, headers, socket.read(headers["Content-Length"].to_i)]
        body = '{"access_token":"tok","expires_in":3600}'
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
        socket.close
      end

      credential = O.exchange_code(
        "http://127.0.0.1:#{port}/token",
        code: "abc", verifier: "ver", client_id: "cid",
        redirect_uri: "http://127.0.0.1:53700/callback",
      )
      form = URI.decode_www_form(captured[2]).to_h
      form["grant_type"].should == "authorization_code"
      form["code_verifier"].should == "ver"
      form["client_id"].should == "cid"
      credential["type"].should == "oauth"
      credential["access"].should == "tok"
      credential["expires"].should.be.kind_of Integer
      credential["tokenEndpoint"].should == "http://127.0.0.1:#{port}/token"
      credential["clientId"].should == "cid"
    end
  end
end
