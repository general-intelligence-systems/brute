# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Brute
  module Store
  # Manages session persistence. Each session is a conversation that can be
  # saved to disk and resumed later.
  #
  # Storage layout (per-session directory):
  #
  #   ~/.brute/sessions/{session-id}/
  #     session.meta.json          # session metadata
  #     context.json               # serialized conversation history
  #     msg_0001.json              # structured messages (OpenCode format)
  #     msg_0002.json
  #     ...
  #
  class Session
    attr_reader :id, :title, :path

    def initialize(id: nil, dir: nil)
      @id = id || SecureRandom.uuid
      @base_dir = dir || File.join(Dir.home, ".brute", "sessions")
      @session_dir = File.join(@base_dir, @id)
      @path = File.join(@session_dir, "context.json")
      @title = nil
      @metadata = {}
      FileUtils.mkdir_p(@session_dir)
    end

    def message_store
      @message_store ||= MessageStore.new(session_id: @id, dir: @session_dir)
    end

    # Serialize an array of LLM::Message objects to disk as JSON.
    def save_messages(messages, title: nil, metadata: {})
      @title = title if title
      @metadata.merge!(metadata)

      data = {
        schema_version: 1,
        messages: messages.map { |m| { role: m.role.to_s, content: m.content.to_s } },
      }
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(data))

      save_meta
    end

    # List all saved sessions, newest first.
    def self.list(dir: nil)
      dir ||= File.join(Dir.home, ".brute", "sessions")

      if File.directory?(dir)
        sessions = Dir.glob(File.join(dir, "*", "session.meta.json")).filter_map do |meta_path|
          data = JSON.parse(File.read(meta_path), symbolize_names: true)
          id = data[:id]
          next unless id
          {
            id: id,
            title: data[:title],
            saved_at: data[:saved_at],
            path: File.join(File.dirname(meta_path), "context.json"),
          }
        end

        sessions.sort_by { |s| s[:saved_at] || "" }.reverse
      else
        []
      end
    end

    def delete
      FileUtils.rm_rf(@session_dir) if File.directory?(@session_dir)
    end

    private

      def meta_path
        File.join(@session_dir, "session.meta.json")
      end

      def save_meta
        data = {
          id: @id,
          title: @title,
          saved_at: Time.now.iso8601,
          metadata: @metadata,
        }
        FileUtils.mkdir_p(@session_dir)
        File.write(meta_path, JSON.pretty_generate(data))
      end

      def load_meta
        return unless File.exist?(meta_path)

        data = JSON.parse(File.read(meta_path), symbolize_names: true)
        @title = data[:title]
        @metadata = data[:metadata] || {}
      end
  end
  end
end
