# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"

module Brute
  # The mirror image of protocol-rack. Where `Protocol::Rack::Adapter` wraps a
  # *Rack app* so an HTTP server can drive it (env in, `[status, headers, body]`
  # out), `Brute::Rack::Adapter` wraps a *Brute agent* so a Rack server can
  # drive it. It is itself a Rack app — `call(env) -> [status, headers, body]` —
  # so any AgentPipeline drops straight into a config.ru and serves over HTTP
  # behind Falcon/Puma/etc:
  #
  #   # config.ru
  #   agent = Brute::Turn::AgentPipeline.parse_file("examples/agents/brute.ru")
  #   run Brute::Rack::Adapter.for(agent)
  #
  #   $ curl -d 'What files are here?' localhost:9292
  #   $ curl -H 'content-type: application/json' -d '{"prompt":"hi"}' localhost:9292
  #   $ curl 'localhost:9292/?prompt=hi'
  #
  # The whole job is two pure transforms — the two directions the request named:
  #
  #   env    -> prompt string      (#prompt_from)   the request half
  #   output -> [status, headers, body] (#response_for) the response half
  #
  # `call` just wires them together around one `agent.start`.
  module Rack
    class Adapter
      # Body/JSON keys we accept a prompt under, in priority order. `prompt`
      # is canonical; `message`/`input` are common aliases.
      PROMPT_KEYS = %w[prompt message input].freeze

      # Convenience factory so the config.ru reads `run Adapter.for(agent)`.
      def self.for(agent) = new(agent)

      # @parameter agent [#start] Anything with `start(prompt) -> env` — an
      #   AgentPipeline, a SubAgent, or any turn-shaped callable.
      def initialize(agent)
        unless agent.respond_to?(:start)
          raise ArgumentError, "agent must respond to #start"
        end

        @agent = agent
      end

      # Rack entry point. Extract the prompt, run one agent turn, render the
      # assistant's reply back as an HTTP response. A missing prompt is a 400
      # (client's fault); anything the turn raises is a 500.
      def call(env)
        prompt = prompt_from(env)
        if prompt.nil? || prompt.empty?
          response_for(env, 400, "No prompt provided.")
        else
          turn = @agent.start(prompt)
          response_for(env, 200, output_of(turn))
        end
      rescue => error
        response_for(env, 500, error.message)
      end

      # env -> prompt string. Four ways in, most explicit first:
      #
      #   1. a `?prompt=` query param (never touches the body),
      #   2. a JSON body — a known key of an object, or a bare JSON string,
      #   3. a form-encoded `prompt=` field,
      #   4. otherwise the raw request body IS the prompt.
      #
      # Returns nil when nothing usable is present.
      def prompt_from(env)
        request = ::Rack::Request.new(env)

        if (query = request.GET["prompt"]) && !query.empty?
          query
        else
          body = read_body(request)
          if body.nil? || body.strip.empty?
            nil
          else
            from_json = nil
            if json?(request.media_type)
              case data = parse_json(body)
              when ::Hash   then from_json = PROMPT_KEYS.filter_map { |key| data[key] }.first&.to_s || body
              when ::String then from_json = data
              end
            end

            if from_json
              from_json
            elsif request.form_data? && (field = ::Rack::Utils.parse_nested_query(body)["prompt"])
              field
            else
              body
            end
          end
        end
      end

      # output -> [status, headers, body]. Content-negotiated: JSON in (or an
      # `Accept: application/json`) gets `{"response": "..."}` back; everything
      # else gets `text/plain`. Errors ride the same path so a 500 body is
      # shaped like a 200 body.
      def response_for(env, status, output)
        text = output.to_s

        if wants_json?(env)
          if status == 200
            key = :response
          else
            key = :error
          end
          [status, {"content-type" => "application/json"}, [::JSON.generate(key => text)]]
        else
          [status, {"content-type" => "text/plain; charset=utf-8"}, [text]]
        end
      end

      private

        # The agent's answer is the last message it appended to the log.
        def output_of(turn)
          if turn.is_a?(::Hash)
            messages = turn[:messages]
          else
            messages = turn
          end
          messages&.last&.content.to_s
        end

        def read_body(request)
          input = request.body
          input&.read
        rescue
          nil
        end

        def json?(media_type)
          media_type.to_s.include?("json")
        end

        def parse_json(body)
          ::JSON.parse(body)
        rescue ::JSON::ParserError
          nil
        end

        # Prefer JSON when the client posted JSON or explicitly accepts it.
        def wants_json?(env)
          json?(env["CONTENT_TYPE"]) || json?(env["HTTP_ACCEPT"])
        end
    end
  end
end

__END__

describe "brute/rack/adapter" do
  require "stringio"
  # Specs are eval'd standalone by the scampi runner, so make sure the pipeline
  # is loaded here; otherwise `Brute.agent` may be undefined.
  require "brute/turn/agent_pipeline"

  # A tiny agent that echoes the prompt straight back through a real turn, and a
  # (stateless, reusable) adapter wrapping it.
  echo_agent = Brute.agent.run(->(env) { env[:messages].assistant("echo: #{env[:messages].last.content}") })
  adapter    = Brute::Rack::Adapter.new(echo_agent)

  # Build a minimal Rack env by hand (no server needed).
  rack_env = lambda do |method: "POST", path: "/", query: "", body: "", type: nil, accept: nil|
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path,
      "QUERY_STRING"   => query,
      "rack.input"     => StringIO.new(body),
    }
    env["CONTENT_TYPE"] = type if type
    env["HTTP_ACCEPT"]  = accept if accept
    env
  end

  it "is a Rack app: env in, [status, headers, body] out" do
    status, headers, body = adapter.call(rack_env.call(body: "hello"))
    status.should == 200
    headers["content-type"].should == "text/plain; charset=utf-8"
    body.first.should == "echo: hello"
  end

  it "reads a raw text body as the prompt" do
    adapter.prompt_from(rack_env.call(body: "what changed?")).should == "what changed?"
  end

  it "reads a JSON body under a known key" do
    env = rack_env.call(body: '{"prompt":"from json"}', type: "application/json")
    adapter.prompt_from(env).should == "from json"
  end

  it "accepts message/input JSON aliases" do
    env = rack_env.call(body: '{"message":"aliased"}', type: "application/json")
    adapter.prompt_from(env).should == "aliased"
  end

  it "reads a bare JSON string body" do
    env = rack_env.call(body: '"just a string"', type: "application/json")
    adapter.prompt_from(env).should == "just a string"
  end

  it "reads a form-encoded prompt field" do
    env = rack_env.call(body: "prompt=formed&x=1", type: "application/x-www-form-urlencoded")
    adapter.prompt_from(env).should == "formed"
  end

  it "reads a ?prompt= query param without consuming the body" do
    env = rack_env.call(method: "GET", query: "prompt=queried", body: "")
    adapter.prompt_from(env).should == "queried"
  end

  it "returns nil for an empty request" do
    adapter.prompt_from(rack_env.call(body: "   ")).should.be.nil
  end

  it "answers a missing prompt with 400" do
    status, _headers, body = adapter.call(rack_env.call(body: ""))
    status.should == 400
    body.first.should == "No prompt provided."
  end

  it "content-negotiates JSON responses" do
    env = rack_env.call(body: '{"prompt":"hi"}', type: "application/json")
    status, headers, body = adapter.call(env)
    status.should == 200
    headers["content-type"].should == "application/json"
    JSON.parse(body.first).should == { "response" => "echo: hi" }
  end

  it "honors an Accept: application/json header" do
    env = rack_env.call(body: "hi", accept: "application/json")
    _status, headers, _body = adapter.call(env)
    headers["content-type"].should == "application/json"
  end

  it "renders a raised turn as a 500 (JSON error key when negotiated)" do
    boom = Brute.agent.run(->(_env) { raise "kaboom" })
    env  = rack_env.call(body: '{"prompt":"hi"}', type: "application/json")
    status, _headers, body = Brute::Rack::Adapter.new(boom).call(env)
    status.should == 500
    JSON.parse(body.first).should == { "error" => "kaboom" }
  end

  it ".for is a factory and #start is required" do
    Brute::Rack::Adapter.for(echo_agent).should.be.kind_of?(Brute::Rack::Adapter)
    lambda { Brute::Rack::Adapter.new(Object.new) }.should.raise(ArgumentError)
  end
end
