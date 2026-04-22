# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Brute
  # Manages session persistence. Each session is a conversation that can be
  # saved to disk and resumed later.
  #
  # New directory-based layout (per-session directory):
  #
  #   ~/.brute/sessions/{session-id}/
  #     session.meta.json          # session metadata
  #     context.json               # llm.rb context blob (for resumption)
  #     msg_0001.json              # structured messages (OpenCode format)
  #     msg_0002.json
  #     ...
  #
  # Also supports the legacy flat layout for reading:
  #
  #   ~/.brute/sessions/{session-id}.json
  #   ~/.brute/sessions/{session-id}.meta.json
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

      # Check for legacy flat-file layout and migrate path if present
      @legacy_path = File.join(@base_dir, "#{@id}.json")
      @legacy_meta = File.join(@base_dir, "#{@id}.meta.json")
    end

    def message_store
      @message_store ||= MessageStore.new(session_id: @id, dir: @session_dir)
    end

    def save(context, title: nil, metadata: {})
      @title = title if title
      @metadata.merge!(metadata)

      context.save(path: @path)

      save_meta
    end

    def restore(context)
      if File.exist?(@path)
        ctx_path = @path
      elsif File.exist?(@legacy_path)
        ctx_path = @legacy_path
      end

      if ctx_path
        context.restore(path: ctx_path)
        load_meta
        true
      else
        false
      end
    end

    # List all saved sessions, newest first.
    # Scans both new directory-based layout and legacy flat files.
    def self.list(dir: nil)
      dir ||= File.join(Dir.home, ".brute", "sessions")

      if File.directory?(dir)
        sessions = {}

        # New layout: {id}/session.meta.json
        Dir.glob(File.join(dir, "*", "session.meta.json")).each do |meta_path|
          data = JSON.parse(File.read(meta_path), symbolize_names: true)
          id = data[:id]
          next unless id
          sessions[id] = {
            id: id,
            title: data[:title],
            saved_at: data[:saved_at],
            path: File.join(File.dirname(meta_path), "context.json"),
          }
        end

        # Legacy layout: {id}.meta.json (only if not already found)
        Dir.glob(File.join(dir, "*.meta.json")).each do |meta_path|
          # Skip files inside session subdirectories
          next if meta_path.include?("/session.meta.json")
          data = JSON.parse(File.read(meta_path), symbolize_names: true)
          id = data[:id]
          next unless id
          next if sessions.key?(id)  # new layout takes precedence
          sessions[id] = {
            id: id,
            title: data[:title],
            saved_at: data[:saved_at],
            path: meta_path.sub(/\.meta\.json$/, ".json"),
          }
        end

        sessions.values.sort_by { |s| s[:saved_at] || "" }.reverse
      else
        []
      end
    end

    def delete
      FileUtils.rm_rf(@session_dir) if File.directory?(@session_dir)
      File.delete(@legacy_path) if File.exist?(@legacy_path)
      File.delete(@legacy_meta) if File.exist?(@legacy_meta)
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
        if File.exist?(meta_path)
          path = meta_path
        elsif File.exist?(@legacy_meta)
          path = @legacy_meta
        end

        if path
          data = JSON.parse(File.read(path), symbolize_names: true)
          @title = data[:title]
          @metadata = data[:metadata] || {}
        end
      end
  end
end
