# frozen_string_literal: true

require "json"
require "fileutils"

require "bundler/setup"
require "brute"

module Brute
  class Session < Array
    attr_reader :path

    def initialize(path: nil)
      super()
      @path = path
      if @path
        FileUtils.mkdir_p(File.dirname(@path))
        if File.exist?(@path)
          File.foreach(@path) do |line|
            line.strip!
            # Use push to bypass append persistence (avoids re-writing existing lines)
            push(RubyLLM::Message.new(**JSON.parse(line, symbolize_names: true))) if line.present?
          end
        end
      end
    end

    # @deprecated Use Session.new(path:) instead.
    def self.from_jsonl(path)
      new(path: path)
    end

    # Append a message and persist it to disk if a path is set.
    def <<(msg)
      super
      if @path
        File.open(@path, "a") { |f| f.puts(JSON.generate(msg.to_h)) }
      end
      self
    end

    def user(content)
      self << RubyLLM::Message.new(role: :user, content: content)
    end

    def assistant(content)
      self << RubyLLM::Message.new(role: :assistant, content: content)
    end

    def system(content)
      self << RubyLLM::Message.new(role: :system, content: content)
    end
  end
end
