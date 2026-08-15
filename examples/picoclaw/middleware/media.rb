# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"

# Media — picoclaw's media store + resolver (pkg/media/store.go, tempdir.go;
# pkg/agent/agent_media.go:60-149).
#
# Store: registers an EXISTING local file under a scope (no copy/move) and
# hands out a media://<uuid> ref. Refcounted per path: the first ref's cleanup
# policy decides deletability, and any forget_only ref makes the path
# non-deletable forever. ReleaseAll(scope) and the TTL janitor
# (tools.media_cleanup: max_age_minutes 30) delete only store-managed files.
#
# Resolver (runs pre-loop): media:// refs in message content are rewritten to
# path tags — [image:/path], [audio:/path], [video:/path], [file:/path] —
# replacing generic placeholders or appended. Upstream also base64-inlines
# current-turn tool images into a synthetic user message with image parts;
# brute's message transport carries plain-string content only, so the inline
# path is out of reach for now (noted gap; path tags carry the reference).
#
# env reads: :messages. env writes: :messages (path tags). Side effects: temp
# dir janitor sweep, ref bookkeeping.
class Media
  MEDIA_DIR = File.join(Dir.tmpdir, "picoclaw_media")
  REF_PREFIX = "media://"

  # FileMediaStore port.
  class Store
    Entry = Struct.new(:path, :meta, :stored_at)

    def initialize(dir: MEDIA_DIR, max_age_minutes: 30, now: nil)
      @dir = dir
      @max_age_seconds = max_age_minutes.to_i * 60
      @now = now || -> { Time.now }
      @refs = {}          # ref => Entry
      @scope_to_refs = Hash.new { |h, k| h[k] = [] }
      @path_states = {}   # path => { count:, deletable: }
      @mutex = Mutex.new
    end

    # meta: { filename:, content_type:, source:, cleanup_policy: "delete_on_cleanup"|"forget_only" }
    def store(local_path, meta: {}, scope:)
      raise "media store: #{local_path}: no such file" unless File.exist?(local_path)

      ref = "#{REF_PREFIX}#{SecureRandom.uuid}"
      policy = meta[:cleanup_policy] || meta["cleanup_policy"] || "delete_on_cleanup"

      @mutex.synchronize do
        @refs[ref] = Entry.new(local_path, meta, @now.call)
        @scope_to_refs[scope] << ref
        state = (@path_states[local_path] ||= { count: 0, deletable: true })
        if state[:count].zero?
          state[:deletable] = policy == "delete_on_cleanup"
        elsif policy == "forget_only"
          state[:deletable] = false
        end
        state[:count] += 1
      end
      ref
    end

    def resolve(ref)
      entry = @mutex.synchronize { @refs[ref] }
      raise "media store: unknown ref: #{ref}" unless entry

      entry.path
    end

    def resolve_with_meta(ref)
      entry = @mutex.synchronize { @refs[ref] }
      raise "media store: unknown ref: #{ref}" unless entry

      [entry.path, entry.meta]
    end

    def release_all(scope)
      paths = @mutex.synchronize do
        refs = @scope_to_refs.delete(scope) || []
        refs.filter_map { |ref| release_ref(ref) }
      end
      paths.each { |path| File.delete(path) rescue (raise unless $!.is_a?(Errno::ENOENT)) }
      nil
    end

    # TTL janitor (CleanExpired port); runs once per turn from the middleware.
    def clean_expired
      return 0 if @max_age_seconds <= 0

      cutoff = @now.call - @max_age_seconds
      paths = @mutex.synchronize do
        expired = @refs.select { |_, e| e.stored_at < cutoff }.keys
        expired.filter_map do |ref|
          entry = @refs[ref]
          @scope_to_refs.each_value { |refs| refs.delete(ref) }
          @scope_to_refs.reject! { |_, refs| refs.empty? }
          release_ref(ref, fallback: entry&.path)
        end
      end
      paths.each { |path| File.delete(path) rescue (raise unless $!.is_a?(Errno::ENOENT)) }
      paths.size
    end

    private

    # Removes the ref; returns the path to delete when its last ref is gone
    # and it is store-managed.
    def release_ref(ref, fallback: nil)
      entry = @refs.delete(ref)
      path = (entry&.path || fallback).to_s
      state = @path_states[path]
      return nil unless state

      state[:count] -= 1
      return nil unless state[:count] <= 0

      @path_states.delete(path)
      state[:deletable] ? path : nil
    end
  end

  def initialize(app, store: Store.new, enabled_cleanup: true)
    @app = app
    @store = store
    @enabled_cleanup = enabled_cleanup
  end

  def call(env)
    @store.clean_expired if @enabled_cleanup
    env[:metadata][:media_store] = @store
    resolve_refs(env[:messages])
    @app.call(env)
  end

  private

  # resolveMediaRefs port (path-tag part): media:// refs become
  # [type:/path] tags; unresolvable refs are dropped.
  def resolve_refs(messages)
    messages.each_with_index do |message, i|
      content = message.content.to_s
      next unless content.include?(REF_PREFIX)

      new_content = content.gsub(%r{media://[0-9a-f-]{36}}) do |ref|
        begin
          path, meta = @store.resolve_with_meta(ref)
          "[#{tag_kind(meta, path)}:#{path}]"
        rescue StandardError
          "" # dropped (upstream logs + drops)
        end
      end
      messages[i] = message.with(content: new_content) if new_content != content
    end
  end

  def tag_kind(meta, path)
    mime = (meta[:content_type] || meta["content_type"]).to_s
    mime = mime_for(path) if mime.empty?
    %w[image audio video].each { |kind| return kind if mime.start_with?("#{kind}/") }
    "file"
  end

  def mime_for(path)
    case File.extname(path).downcase
    when ".jpg", ".jpeg" then "image/jpeg"
    when ".png" then "image/png"
    when ".gif" then "image/gif"
    when ".webp" then "image/webp"
    when ".bmp" then "image/bmp"
    when ".mp3" then "audio/mpeg"
    when ".wav" then "audio/wav"
    when ".ogg" then "audio/ogg"
    when ".mp4" then "video/mp4"
    when ".webm" then "video/webm"
    else "application/octet-stream"
    end
  end

end
