# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Brute
  class Session < Array
    def self.from_jsonl(path)
      new.tap do |s|
        next unless File.exist?(path)
        File.foreach(path) do |line|
          line = line.strip
          next if line.empty?
          s << RubyLLM::Message.new(**JSON.parse(line, symbolize_names: true))
        end
      end
    end

    def user(content);      self << RubyLLM::Message.new(role: :user, content: content); end
    def assistant(content); self << RubyLLM::Message.new(role: :assistant, content: content); end
    def system(content);    self << RubyLLM::Message.new(role: :system, content: content); end
  end
end
