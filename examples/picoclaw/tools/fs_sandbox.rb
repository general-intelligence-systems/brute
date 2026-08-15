# frozen_string_literal: true

require "fileutils"
require "pathname"

# FsSandbox — the shared filesystem layer every picoclaw fs tool routes
# through. Port of pkg/tools/fs/filesystem.go's fileSystem machinery +
# pkg/fileutil/file.go's WriteFileAtomic.
#
#   HostFs      — restrict_to_workspace: false. Direct host ops; atomic writes.
#   SandboxFs   — every path validated against the workspace before the op:
#                 lexical escape -> "path escapes workspace: X"; symlink
#                 resolving outside -> "access denied". (Go enforces via
#                 os.Root; Ruby has no equivalent, so we enforce by resolution
#                 — the observable contract is the same: escapes rejected
#                 before any data op.)
#   WhitelistFs — restricted + allow_read/allow_write regexes: matching
#                 ABSOLUTE paths route to HostFs, everything else SandboxFs.
#
# One deliberate difference: Go renders OS errors via %w ("open /x: no such
# file or directory"); Ruby renders exception messages ("No such file or
# directory - /x"). Message prefixes match upstream; trailing OS text differs.
module FsSandbox
  # Carries the upstream-formatted message; `kind` lets callers distinguish
  # :not_found (append_file creates on it) from :denied/:escape/:invalid/:other.
  class Error < StandardError
    attr_reader :kind

    def initialize(kind, message)
      @kind = kind
      super(message)
    end
  end

  module_function

  # --- path helpers (filepath.* ports) --------------------------------------

  def clean(path) = Pathname.new(path.to_s).cleanpath.to_s

  # filepath.IsLocal. Both upstream call sites apply it to Clean/Rel output
  # (where ".." can only ever be leading), so the leading check is exact.
  def local?(rel)
    return false if rel.empty?
    return false if rel.start_with?("/")

    rel != ".." && !rel.start_with?("../")
  end

  # filepath.Rel + IsLocal via Pathname; different roots -> not within.
  def within?(candidate, root)
    rel =
      begin
        Pathname.new(clean(candidate)).relative_path_from(Pathname.new(clean(root))).to_s
      rescue ArgumentError
        return false
      end
    rel == "." || local?(rel)
  end

  def resolve_existing_ancestor(path)
    current = clean(path)
    loop do
      begin
        return File.realpath(current)
      rescue Errno::ENOENT
        parent = File.dirname(current)
        raise Error.new(:invalid, "failed to resolve path: no such file or directory") if parent == current

        current = parent
      rescue SystemCallError => e
        raise Error.new(:invalid, "failed to resolve path: #{e.message}")
      end
    end
  end

  # Realpath the nearest existing ancestor and re-apply the trailing suffix.
  # nil on any failure (upstream maps the error to false at call sites).
  def resolve_against_existing_ancestor(path)
    cleaned = clean(path)
    current = cleaned
    loop do
      begin
        resolved = File.realpath(current)
        suffix =
          begin
            Pathname.new(cleaned).relative_path_from(Pathname.new(current)).to_s
          rescue ArgumentError
            return nil
          end
        return suffix == "." ? clean(resolved) : clean(File.join(resolved, suffix))
      rescue Errno::ENOENT
        parent = File.dirname(current)
        return nil if parent == current

        current = parent
      rescue SystemCallError
        return nil
      end
    end
  end

  # --- allowlist (isAllowedPath / extractAllowedPathRoot ports) -------------

  REGEX_META = [".", "+", "*", "?", "(", ")", "[", "]", "{", "}", "|"].freeze

  def allowed_path?(path, patterns)
    return false if patterns.nil? || patterns.empty?

    cleaned = clean(path)
    return false unless cleaned.start_with?("/") # only absolute paths are allow-listable
    return false unless matches_allowed_path?(cleaned, patterns)

    resolved = resolve_against_existing_ancestor(cleaned)
    !resolved.nil? && matches_allowed_path?(resolved, patterns)
  end

  def matches_allowed_path?(path, patterns)
    cleaned = clean(path)
    patterns.any? do |pattern|
      pattern.match?(cleaned) ||
        ((root = extract_allowed_root(pattern)) && within_allowed_root?(cleaned, root))
    end
  end

  # Recognizes the anchored-literal form ^<dir>(?:/|$) and returns the literal
  # dir for prefix matching; nil for arbitrary regexes.
  def extract_allowed_root(pattern)
    raw = pattern.source
    return nil unless raw.start_with?("^")

    literal = raw[1..]
    literal = literal.delete_suffix("(?:/|$)")
    literal = literal.delete_suffix('(?:\\\\|$)')
    return nil if unescaped_regex_meta?(literal)

    unescaped = unescape_regex_literal(literal)
    return nil if unescaped.nil? || unescaped.empty? || !unescaped.start_with?("/")

    clean(unescaped)
  end

  def unescaped_regex_meta?(str)
    escaped = false
    str.each_char do |ch|
      if escaped
        escaped = false
        next
      end
      if ch == "\\"
        escaped = true
        next
      end
      return true if REGEX_META.include?(ch)
    end
    escaped
  end

  def unescape_regex_literal(str)
    out = +""
    escaped = false
    str.each_char do |ch|
      if escaped
        out << ch
        escaped = false
      elsif ch == "\\"
        escaped = true
      else
        out << ch
      end
    end
    escaped ? nil : out
  end

  def within_allowed_root?(path, root)
    candidate = clean(path)
    variants = [clean(root)]
    if (resolved = resolve_against_existing_ancestor(root)) && resolved != variants.first
      variants << clean(resolved)
    end
    variants.any? { |allowed| within?(candidate, allowed) }
  end

  # --- validatePathWithAllowPaths (used by exec's cwd + the media tools) ----

  def validate_path(path, workspace:, restrict:, patterns: [])
    raise Error.new(:invalid, "workspace is not defined") if workspace.to_s.empty?

    abs_workspace = File.expand_path(workspace)
    abs_path =
      if Pathname.new(path.to_s).absolute?
        clean(path)
      else
        File.expand_path(File.join(abs_workspace, path.to_s))
      end

    return abs_path unless restrict
    return abs_path if allowed_path?(abs_path, patterns)
    raise Error.new(:denied, "access denied: path is outside the workspace") unless within?(abs_path, abs_workspace)

    workspace_real =
      begin
        File.realpath(abs_workspace)
      rescue SystemCallError
        abs_workspace
      end

    begin
      resolved = File.realpath(abs_path)
      unless within?(resolved, workspace_real)
        raise Error.new(:denied, "access denied: symlink resolves outside workspace")
      end
    rescue Errno::ENOENT
      # New file: validate the nearest existing ancestor instead.
      parent = resolve_existing_ancestor(File.dirname(abs_path))
      unless within?(parent, workspace_real)
        raise Error.new(:denied, "access denied: symlink resolves outside workspace")
      end
    end

    abs_path
  end

  # --- atomic writes (WriteFileAtomic port) ---------------------------------

  def tmp_name = ".tmp-#{Process.pid}-#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}"

  # Best-effort directory fsync — upstream ignores dir-sync errors on purpose.
  def sync_dir(dir)
    d = File.open(dir)
    d.fsync
    d.close
  rescue SystemCallError, IOError
    nil
  end

  # hostFs.WriteFile: temp in the SAME directory, 0o600, fsync, rename, dir sync.
  def atomic_write(path, data, perm: 0o600)
    dir = File.dirname(path)
    begin
      FileUtils.mkdir_p(dir, mode: 0o755)
    rescue SystemCallError => e
      raise Error.new(:other, "failed to create directory: #{e.message}")
    end

    tmp_path = File.join(dir, tmp_name)
    tmp =
      begin
        File.open(tmp_path, File::WRONLY | File::CREAT | File::EXCL, perm)
      rescue SystemCallError => e
        raise Error.new(:other, "failed to create temp file: #{e.message}")
      end

    cleanup = true
    begin
      begin
        tmp.write(data)
      rescue SystemCallError => e
        raise Error.new(:other, "failed to write temp file: #{e.message}")
      end
      begin
        tmp.fsync
      rescue SystemCallError => e
        raise Error.new(:other, "failed to sync temp file: #{e.message}")
      end
      begin
        tmp.chmod(perm)
      rescue SystemCallError => e
        raise Error.new(:other, "failed to set permissions: #{e.message}")
      end
      begin
        tmp.close
      rescue SystemCallError => e
        raise Error.new(:other, "failed to close temp file: #{e.message}")
      end
      begin
        File.rename(tmp_path, path)
      rescue SystemCallError => e
        raise Error.new(:other, "failed to rename temp file: #{e.message}")
      end
      sync_dir(dir)
      cleanup = false
    ensure
      if cleanup
        begin
          tmp.close unless tmp.closed?
        rescue IOError
          nil
        end
        File.delete(tmp_path)
      end
    end
    nil
  end

  # --- backends ---------------------------------------------------------------

  class HostFs
    def read_file(path)
      File.binread(path)
    rescue Errno::ENOENT => e
      raise Error.new(:not_found, "failed to read file: file not found: #{e.message}")
    rescue Errno::EACCES => e
      raise Error.new(:denied, "failed to read file: access denied: #{e.message}")
    rescue SystemCallError => e
      raise Error.new(:other, "failed to read file: #{e.message}")
    end

    def open(path)
      File.open(path, "rb")
    rescue Errno::ENOENT => e
      raise Error.new(:not_found, "failed to open file: file not found: #{e.message}")
    rescue Errno::EACCES => e
      raise Error.new(:denied, "failed to open file: access denied: #{e.message}")
    rescue SystemCallError => e
      raise Error.new(:other, "failed to open file: #{e.message}")
    end

    # Raw semantics — callers (list_dir) wrap errors themselves, like upstream.
    # Returns [absolute path used, sorted entry names] so callers can lstat
    # entries with DirEntry-like (lstat) semantics.
    def read_dir(path)
      abs = File.expand_path(path.to_s)
      [abs, Dir.children(abs).sort]
    end

    def write_file(path, data)
      FsSandbox.atomic_write(path, data)
    end
  end

  class SandboxFs
    def initialize(workspace)
      @workspace = workspace
    end

    # getSafeRelPath port.
    def safe_rel(path)
      raise Error.new(:invalid, "workspace is not defined") if @workspace.to_s.empty?

      rel = FsSandbox.clean(path)
      if rel.start_with?("/")
        rel =
          begin
            Pathname.new(rel).relative_path_from(Pathname.new(FsSandbox.clean(@workspace))).to_s
          rescue ArgumentError => e
            raise Error.new(:invalid, "failed to calculate relative path: #{e.message}")
          end
      end
      raise Error.new(:escape, "path escapes workspace: #{path}") unless FsSandbox.local?(rel)

      rel
    end

    # os.Root enforcement port: resolve the (possibly not-yet-existing) target
    # through symlinks and require containment in the real workspace root.
    def checked_abs(path, denied_message)
      rel = safe_rel(path)
      abs = File.join(@workspace, rel)
      root_real =
        begin
          File.realpath(@workspace)
        rescue SystemCallError
          @workspace
        end
      resolved = FsSandbox.resolve_against_existing_ancestor(abs)
      if resolved.nil? || !FsSandbox.within?(resolved, root_real)
        raise Error.new(:denied, denied_message)
      end
      abs
    end

    def read_file(path)
      HostFs.new.read_file(checked_abs(path, "failed to read file: access denied: path escapes from parent"))
    end

    def open(path)
      HostFs.new.open(checked_abs(path, "failed to open file: access denied: path escapes from parent"))
    end

    def read_dir(path)
      abs = checked_abs(path, "path escapes from parent")
      [abs, Dir.children(abs).sort]
    end

    # sandboxFs.WriteFile: temp in the workspace ROOT, rename over target,
    # fsync the workspace root dir.
    def write_file(path, data)
      rel = safe_rel(path)
      abs = File.join(@workspace, rel)
      root_real =
        begin
          File.realpath(@workspace)
        rescue SystemCallError
          @workspace
        end
      resolved = FsSandbox.resolve_against_existing_ancestor(abs)
      if resolved.nil? || !FsSandbox.within?(resolved, root_real)
        raise Error.new(:denied, "failed to rename temp file over target: path escapes from parent")
      end

      parent = File.dirname(abs)
      begin
        FileUtils.mkdir_p(parent, mode: 0o755)
      rescue SystemCallError => e
        raise Error.new(:other, "failed to create parent directories: #{e.message}")
      end

      tmp_abs = File.join(@workspace, FsSandbox.tmp_name)
      tmp =
        begin
          File.open(tmp_abs, File::WRONLY | File::CREAT | File::EXCL, 0o600)
        rescue SystemCallError => e
          begin
            File.delete(tmp_abs)
          rescue SystemCallError
            nil
          end
          raise Error.new(:other, "failed to open temp file: #{e.message}")
        end

      begin
        begin
          tmp.write(data)
        rescue SystemCallError => e
          raise Error.new(:other, "failed to write temp file: #{e.message}")
        end
        begin
          tmp.fsync
        rescue SystemCallError => e
          raise Error.new(:other, "failed to sync temp file: #{e.message}")
        end
        begin
          tmp.close
        rescue SystemCallError => e
          raise Error.new(:other, "failed to close temp file: #{e.message}")
        end
        begin
          File.rename(tmp_abs, abs)
        rescue SystemCallError => e
          raise Error.new(:other, "failed to rename temp file over target: #{e.message}")
        end
        FsSandbox.sync_dir(@workspace)
      ensure
        begin
          tmp.close unless tmp.closed?
        rescue IOError
          nil
        end
        File.delete(tmp_abs) if File.exist?(tmp_abs)
      end
      nil
    end
  end

  class WhitelistFs
    def initialize(workspace:, patterns:)
      @sandbox = SandboxFs.new(workspace)
      @host = HostFs.new
      @patterns = patterns
    end

    def read_file(path) = route(path) { |fs, p| fs.read_file(p) }
    def open(path) = route(path) { |fs, p| fs.open(p) }
    def read_dir(path) = route(path) { |fs, p| fs.read_dir(p) }
    def write_file(path, data) = route(path) { |fs, p| fs.write_file(p, data) }

    private

    # Only absolute paths can match the whitelist (upstream isAllowedPath);
    # relative paths always fall to the sandbox.
    def route(path)
      if FsSandbox.allowed_path?(path, @patterns)
        yield @host, path
      else
        yield @sandbox, path
      end
    end
  end

  def build_fs(workspace, restrict, patterns)
    return HostFs.new unless restrict

    sandbox = SandboxFs.new(workspace)
    patterns.nil? || patterns.empty? ? sandbox : WhitelistFs.new(workspace: workspace, patterns: patterns)
  end

  # --- binary sniffing (isBinaryReadFileData port) ----------------------------

  # Minimal http.DetectContentType port: the magic-signature table plus
  # HTML/XML text detection. Everything else falls to "text/plain" here and is
  # caught by the UTF-8/control-char checks in binary_data?.
  BINARY_SIGNATURES = [
    ["%PDF-".b, "application/pdf"],
    ["PK\x03\x04".b, "application/zip"],
    ["PK\x05\x06".b, "application/zip"],
    ["\x1F\x8B".b, "application/gzip"],
    ["BZh".b, "application/bzip2"],
    ["7z\xBC\xAF\x27\x1C".b, "application/x-7z-compressed"],
    ["Rar!\x1A\x07".b, "application/x-rar-compressed"],
    ["\xFD7zXZ\x00".b, "application/x-xz"],
    ["\x28\xB5\x2F\xFD".b, "application/zstd"],
    ["\x89PNG\r\n\x1A\n".b, "image/png"],
    ["\xFF\xD8\xFF".b, "image/jpeg"],
    ["GIF8".b, "image/gif"],
    ["BM".b, "image/bmp"],
    ["\x7FELF".b, "application/octet-stream"],
    ["SQLite format 3\x00".b, "application/octet-stream"],
    ["\x00asm".b, "application/wasm"],
    ["\xCA\xFE\xBA\xBE".b, "application/octet-stream"],
    ["ID3".b, "audio/mpeg"],
    ["OggS".b, "application/ogg"],
    ["fLaC".b, "audio/flac"],
  ].freeze

  TEXT_SIGNATURES = %w[<?xml <!DOCTYPE <html <head <script <body].freeze

  def detect_content_type(sample)
    stripped = sample.sub(/\A[\x09\x0A\x0B\x0C\x0D\x20]+/, "")
    TEXT_SIGNATURES.each do |sig|
      return "text/plain; charset=utf-8" if stripped.start_with?(sig) || stripped.downcase.start_with?(sig.downcase)
    end
    BINARY_SIGNATURES.each do |magic, type|
      return type if sample.start_with?(magic)
    end
    return "application/x-tar" if sample.bytesize > 262 && sample.byteslice(257, 5) == "ustar".b

    "text/plain; charset=utf-8"
  end

  # isBinaryReadFileData port: NUL byte, non-text sniffed type, invalid UTF-8,
  # or >10% control characters (excluding \n \r \t \f \b).
  def binary_data?(data)
    return false if data.nil? || data.empty?

    sample = data.bytesize > 512 ? data.byteslice(0, 512) : data
    return true if sample.include?("\x00".b)

    content_type = detect_content_type(sample)
    return false if content_type.start_with?("text/")
    unless content_type.end_with?("/json", "+json", "/xml", "+xml") || content_type.include?("javascript")
      return true unless sample.dup.force_encoding(Encoding::UTF_8).valid_encoding?

      bytes = sample.bytes
      control = bytes.count { |b| b < 0x20 && ![0x0A, 0x0D, 0x09, 0x0C, 0x08].include?(b) }
      return control.to_f / bytes.size > 0.1
    end
    false
  end
end
