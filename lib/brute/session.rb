# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Brute
  # Manages session persistence. Each session is a conversation that can be
  # saved to disk and resumed later.
  #
  # Sessions are stored as JSON files in a configurable directory
  # (defaults to ~/.brute/sessions/).
  class Session
    attr_reader :id, :title, :path

    def initialize(id: nil, dir: nil)
      @id = id || SecureRandom.uuid
      @dir = dir || File.join(Dir.home, ".brute", "sessions")
      @path = File.join(@dir, "#{@id}.json")
      @title = nil
      @metadata = {}
      FileUtils.mkdir_p(@dir)
    end

    # Save a context to this session file.
    def save(context, title: nil, metadata: {})
      @title = title if title
      @metadata.merge!(metadata)

      data = {
        id: @id,
        title: @title,
        saved_at: Time.now.iso8601,
        metadata: @metadata,
      }

      # Use llm.rb's built-in serialization
      context.save(path: @path)

      # Write metadata sidecar
      meta_path = @path.sub(/\.json$/, ".meta.json")
      File.write(meta_path, JSON.pretty_generate(data))
    end

    # Restore a context from this session file.
    # Returns true if restored successfully, false if no session file found.
    def restore(context)
      return false unless File.exist?(@path)

      context.restore(path: @path)

      # Load metadata sidecar if present
      meta_path = @path.sub(/\.json$/, ".meta.json")
      if File.exist?(meta_path)
        data = JSON.parse(File.read(meta_path), symbolize_names: true)
        @title = data[:title]
        @metadata = data[:metadata] || {}
      end

      true
    end

    # List all saved sessions, newest first.
    def self.list(dir: nil)
      dir ||= File.join(Dir.home, ".brute", "sessions")
      return [] unless File.directory?(dir)

      Dir.glob(File.join(dir, "*.meta.json")).map { |meta_path|
        data = JSON.parse(File.read(meta_path), symbolize_names: true)
        {
          id: data[:id],
          title: data[:title],
          saved_at: data[:saved_at],
          path: meta_path.sub(/\.meta\.json$/, ".json"),
        }
      }.sort_by { |s| s[:saved_at] || "" }.reverse
    end

    # Delete a session from disk.
    def delete
      File.delete(@path) if File.exist?(@path)
      meta_path = @path.sub(/\.json$/, ".meta.json")
      File.delete(meta_path) if File.exist?(meta_path)
    end
  end
end
