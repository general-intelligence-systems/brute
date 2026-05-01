# frozen_string_literal: true

require "json"
require "fileutils"

module Brute
  class Session < Array
    attr_reader :path

    def initialize(path: nil)
      super()
      @path = path
      FileUtils.mkdir_p(File.dirname(@path)) if @path
    end

    # Load a session from a JSONL file. Subsequent appends will persist
    # back to the same file automatically.
    def self.from_jsonl(path)
      new(path: path).tap do |session|
        if File.exist?(path)
          File.foreach(path).map(&:strip).each do |line|
            if line.present?
              # Use push to bypass append persistence (avoids re-writing existing lines)
              session.push(RubyLLM::Message.new(**JSON.parse(line, symbolize_names: true)))
            end
          end
        end
      end
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
