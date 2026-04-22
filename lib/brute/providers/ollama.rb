# frozen_string_literal: true

require "bundler/setup"
require "brute"

# Ensure the Ollama provider is loaded (llm.rb lazy-loads providers).
unless defined?(LLM::Ollama)
  require "llm/providers/ollama"
end

module Brute
  module Providers
    ##
    # Brute-level wrapper around LLM::Ollama for local model inference.
    #
    # Adds environment-variable-based configuration so that all Brute
    # examples and the CLI work out of the box with a local Ollama
    # instance:
    #
    #   OLLAMA_HOST  — base URL (default: http://localhost:11434)
    #   OLLAMA_MODEL — default model (default: llm.rb's default, currently qwen3:latest)
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
    class Ollama < LLM::Ollama
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
        return { host: LLM::Ollama::HOST, port: 11434, ssl: false } if url.nil? || url.empty?

        # Prepend scheme if missing so URI.parse works
        url = "http://#{url}" unless url.match?(%r{\A\w+://})
        uri = URI.parse(url)

        {
          host: uri.host || LLM::Ollama::HOST,
          port: uri.port || 11434,
          ssl: uri.scheme == "https",
        }
      end

      ##
      # @param key [String] ignored (Ollama needs no auth), kept for provider interface
      def initialize(key: "none", **)
        config = self.class.parse_host(ENV["OLLAMA_HOST"])
        super(key: key, host: config[:host], port: config[:port], ssl: config[:ssl], **)
      end

      ##
      # @return [Symbol]
      def name
        :ollama
      end

      ##
      # Returns the default model, preferring OLLAMA_MODEL env var.
      # @return [String]
      def default_model
        ENV["OLLAMA_MODEL"] || super
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
    it "falls back to llm.rb default when OLLAMA_MODEL is not set" do
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
