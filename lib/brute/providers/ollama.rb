# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Providers
    ##
    # Brute-level wrapper for Ollama local model inference.
    #
    # Adds environment-variable-based configuration so that all Brute
    # examples and the CLI work out of the box with a local Ollama
    # instance:
    #
    #   OLLAMA_HOST  -- base URL (default: http://localhost:11434)
    #   OLLAMA_MODEL -- default model (default: qwen3:latest)
    #
    # @example Auto-detect via environment
    #   export OLLAMA_HOST=http://localhost:11434
    #   ruby examples/01_basic_agent.rb
    #
    # @example Remote Ollama server
    #   export OLLAMA_HOST=http://192.168.1.50:11434
    #   export OLLAMA_MODEL=llama3.1:8b
    #   ruby examples/02_fix_a_bug.rb
    #
    class Ollama
      DEFAULT_HOST = "localhost"
      DEFAULT_PORT = 11434

      ##
      # Parse OLLAMA_HOST into host, port, and ssl components.
      # Accepts formats like:
      #   http://localhost:11434
      #   https://ollama.example.com
      #   192.168.1.50:11434
      #   localhost
      #
      # @param url [String, nil] raw OLLAMA_HOST value
      # @return [Hash] with :host, :port, :ssl keys
      def self.parse_host(url)
        return { host: DEFAULT_HOST, port: DEFAULT_PORT, ssl: false } if url.nil? || url.empty?

        # Prepend scheme if missing so URI.parse works
        url = "http://#{url}" unless url.match?(%r{\A\w+://})
        uri = URI.parse(url)

        {
          host: uri.host || DEFAULT_HOST,
          port: uri.port || DEFAULT_PORT,
          ssl: uri.scheme == "https",
        }
      end

      ##
      # @param key [String] ignored (Ollama needs no auth), kept for provider interface
      def initialize(key: "none")
        @key = key
        @host_config = self.class.parse_host(ENV["OLLAMA_HOST"])
      end

      def name
        :ollama
      end

      ##
      # Returns the default model, preferring OLLAMA_MODEL env var.
      def default_model
        ENV["OLLAMA_MODEL"] || "qwen3:latest"
      end

      ##
      # Returns a RubyLLM::Providers::Ollama instance for the configured host.
      def ruby_llm_provider
        @ruby_llm_provider ||= begin
          h = @host_config
          scheme = h[:ssl] ? "https" : "http"
          config = RubyLLM::Configuration.new
          config.ollama_api_base = "#{scheme}://#{h[:host]}:#{h[:port]}"
          config.ollama_api_key = @key if @key != "none"
          RubyLLM::Providers::Ollama.new(config)
        end
      end
    end
  end
end

test do
  parse = proc { |url| Brute::Providers::Ollama.parse_host(url) }

  describe ".parse_host" do
    it "returns defaults for nil" do
      parse.(nil).should == { host: "localhost", port: 11434, ssl: false }
    end

    it "returns defaults for empty string" do
      parse.("").should == { host: "localhost", port: 11434, ssl: false }
    end

    it "parses http URL with port" do
      parse.("http://192.168.1.50:11434").should == { host: "192.168.1.50", port: 11434, ssl: false }
    end

    it "parses https URL" do
      parse.("https://ollama.example.com").should == { host: "ollama.example.com", port: 443, ssl: true }
    end

    it "parses host:port without scheme" do
      parse.("192.168.1.50:11434").should == { host: "192.168.1.50", port: 11434, ssl: false }
    end

    it "parses bare hostname" do
      parse.("myhost").should == { host: "myhost", port: 80, ssl: false }
    end
  end

  describe "#name" do
    it "returns :ollama" do
      provider = Brute::Providers::Ollama.new
      provider.name.should == :ollama
    end
  end

  describe "#default_model" do
    it "falls back to qwen3:latest when OLLAMA_MODEL is not set" do
      original = ENV["OLLAMA_MODEL"]
      ENV.delete("OLLAMA_MODEL")
      provider = Brute::Providers::Ollama.new
      provider.default_model.should == "qwen3:latest"
    ensure
      ENV["OLLAMA_MODEL"] = original if original
    end

    it "uses OLLAMA_MODEL env var when set" do
      original = ENV["OLLAMA_MODEL"]
      ENV["OLLAMA_MODEL"] = "llama3.1:8b"
      provider = Brute::Providers::Ollama.new
      provider.default_model.should == "llama3.1:8b"
    ensure
      ENV["OLLAMA_MODEL"] = original
    end
  end
end
