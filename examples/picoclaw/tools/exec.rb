# frozen_string_literal: true

require "json"
require "open3"
require "pty"
require_relative "fs_sandbox"
require_relative "exec_session"

# exec — picoclaw `pkg/tools/shell.go` (ExecTool) + `pkg/tools/session.go`.
#
# Seven actions: run (sync or background) / list / poll / read / write / kill /
# send-keys. Guard order is upstream's guardCommand exactly: deny patterns
# ALWAYS win (even over custom allows, #3079), then the (config-inal) static
# allowlist, then the workspace path checks (traversal, per-token absolute path
# validation with web-URL/domain exemptions, safe /dev pseudo-devices,
# allow_read_paths, cwd containment).
#
# The `timeout` tool param is declared but intentionally UNUSED — upstream
# never reads it (like cron's tz). Timeout comes only from tools.exec.timeout_seconds.
class Exec < Brute::Tool
  # defaultDenyPatterns port (matched against the LOWERCASED command).
  DEFAULT_DENY_PATTERNS = [
    /\brm\s+-[rf]{1,2}\b/,
    /\bdel\s+\/[fq]\b/,
    /\brmdir\s+\/s\b/,
    /(^|[^-\w])\b(format|mkfs|diskpart)\b\s/,
    /\bdd\s+if=/,
    %r{>\s*/dev/(sd[a-z]|hd[a-z]|vd[a-z]|xvd[a-z]|nvme\d|mmcblk\d|loop\d|dm-\d|md\d|sr\d|nbd\d)},
    /\b(shutdown|reboot|poweroff)\b/,
    /:\(\)\s*\{.*\};\s*:/,
    /\$\([^)]+\)/,
    /\$\{[^}]+\}/,
    /`[^`]+`/,
    /\|\s*sh\b/,
    /\|\s*bash\b/,
    /;\s*rm\s+-[rf]/,
    /&&\s*rm\s+-[rf]/,
    /\|\|\s*rm\s+-[rf]/,
    /<<\s*EOF/,
    /\$\(\s*cat\s+/,
    /\$\(\s*curl\s+/,
    /\$\(\s*wget\s+/,
    /\$\(\s*which\s+/,
    /\bsudo\b/,
    /\bchmod\s+[0-7]{3,4}\b/,
    /\bchown\b/,
    /\bpkill\b/,
    /\bkillall\b/,
    /\bkill\b/,
    /\bcurl\b.*\|\s*(sh|bash)/,
    /\bwget\b.*\|\s*(sh|bash)/,
    /\bnpm\s+install\s+-g\b/,
    /\bpip\s+install\s+--user\b/,
    /\bapt\s+(install|remove|purge)\b/,
    /\byum\s+(install|remove)\b/,
    /\bdnf\s+(install|remove)\b/,
    /\bdocker\s+run\b/,
    /\bdocker\s+exec\b/,
    /\bgit\s+push\b/,
    /\bgit\s+force\b/,
    /\bssh\b.*@/,
    /\beval\b/,
    /\bsource\s+.*\.sh\b/,
  ].freeze

  # windowsDenyPatterns port (PowerShell-encoded-command constructions).
  WINDOWS_DENY_PATTERNS = [
    /\[(?:\w+\.)?text\.encoding\]/,
    / -e(?:$|\s)| -ec(?:$|\s)| -enc(?:$|\s)| -en(?:$|\s)| -encodedcommand\b/,
    /\.getstring\s*\(\s*\[byte\[\]/,
    /frombase64string\(/,
    /\$[a-zA-Z_]\w*\s*=\s*\[byte\[\]/,
    /\\u[0-9a-fA-F]{4}/,
  ].freeze

  ABSOLUTE_PATH_PATTERN = /[A-Za-z]:\\[^\\"']+|\/[^\s"']+/
  TRAVERSAL_PATTERN = %r{\.\.(?:[\\/]\.\.)*[\\/]}

  # Kernel pseudo-devices always safe to reference.
  SAFE_PATHS = %w[/dev/null /dev/zero /dev/random /dev/urandom /dev/stdin /dev/stdout /dev/stderr].freeze
  WEB_SCHEMES = %w[http: https: ftp: ftps: sftp: ssh: git:].freeze
  INTERNAL_CHANNELS = %w[cli system subagent].freeze
  TOKEN_BOUNDARIES = [" ", "\t", ":", ";", "|", "&", "<", ">", "'", '"', "`", "\n", "\r"].freeze
  COMMON_FILE_EXTENSIONS = %w[
    py js ts tsx jsx go rs rb php java c cpp h hpp cs swift kt scala
    sh bash zsh fish ps1 bat cmd txt md rst log json yaml yml toml
    xml html css scss ini cfg conf env exe dll so dylib lib a o obj
    zip tar gz bz2 xz 7z rar png jpg jpeg gif svg ico bmp webp
    mp3 mp4 wav avi mov mkv flac pdf doc docx xls xlsx ppt pptx
    pub pem key crt cer p12 pfx bak tmp swp lock ttf otf woff woff2 eot
    deb rpm apk msi dmg sql sqlite db
  ].freeze

  MAX_SYNC_OUTPUT = 10_000

  description "Execute shell commands. Use background=true for long-running commands (returns " \
              "sessionId). Use pty=true for interactive commands (can combine with " \
              "background=true). Use poll/read/write/send-keys/kill with sessionId to manage " \
              "background sessions. Sessions auto-cleanup 30 minutes after process exits; use " \
              "kill to terminate early. Output buffer limit: 1MB."
  params({
    "type" => "object",
    "properties" => {
      "action" => { "type" => "string", "enum" => %w[run list poll read write kill send-keys], "description" => "Action: run (execute command), list (show sessions), poll (check status), read (get output), write (send input), kill (terminate), send-keys (send keys to PTY)" },
      "command" => { "type" => "string", "description" => "Shell command to execute (required for run)" },
      "sessionId" => { "type" => "string", "description" => "Session ID (required for poll/read/write/kill/send-keys)" },
      "keys" => { "type" => "string", "description" => "Key names for send-keys: up, down, left, right, enter, tab, escape, backspace, ctrl-c, ctrl-d, home, end, pageup, pagedown, f1-f12" },
      "data" => { "type" => "string", "description" => "Data to write to stdin (required for write)" },
      "background" => { "type" => "string", "description" => "Run in background immediately" },
      "pty" => { "type" => "string", "description" => "Run in a pseudo-terminal (PTY) when available" },
      "cwd" => { "type" => "string", "description" => "Working directory for the command" },
      "timeout" => { "type" => "integer", "description" => "Timeout in seconds (0 = no timeout)" },
    },
    "required" => ["action"],
  })

  def initialize(workspace:, restrict: true, timeout: nil, enable_deny_patterns: true,
                 allow_remote: true, custom_deny_patterns: [], custom_allow_patterns: [],
                 allow_paths: [], session_manager: ExecSessionManager.instance)
    @working_dir = workspace
    @restrict_to_workspace = restrict
    @timeout = timeout.to_i.positive? ? timeout.to_i : nil # nil = no timeout
    @allow_remote = allow_remote
    @allowed_path_patterns = allow_paths || []
    @session_manager = session_manager
    @allow_patterns = [] # static allowlist: exists upstream (SetAllowPatterns) but is never configured

    @deny_patterns = []
    if enable_deny_patterns
      @deny_patterns.concat(DEFAULT_DENY_PATTERNS)
      @deny_patterns.concat(WINDOWS_DENY_PATTERNS) if windows?
      custom_deny_patterns.each do |pattern|
        @deny_patterns << compile_custom(pattern, "deny")
      end
    end
    @custom_allow_patterns = custom_allow_patterns.map { |pattern| compile_custom(pattern, "allow") }
  end

  def name = "exec"

  def execute(**args)
    action = args[:action].is_a?(String) ? args[:action] : ""
    return "action is required" if action.empty?

    case action
    when "run" then execute_run(args)
    when "list" then execute_list
    when "poll" then execute_poll(args)
    when "read" then execute_read(args)
    when "write" then execute_write(args)
    when "kill" then execute_kill(args)
    when "send-keys" then execute_send_keys(args)
    else "unknown action: #{action}"
    end
  rescue FsSandbox::Error => e
    e.message
  rescue StandardError => e
    warn("exec crashed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    e.message
  end

  private

  # --- run --------------------------------------------------------------------

  def execute_run(args)
    command = args[:command]
    return "command is required" unless command.is_a?(String)

    # GHSA-pv8c-p6jf-3fpp: fail-closed gate for non-internal channels. The
    # port has no channel context, so only the __channel arg carries it.
    unless @allow_remote
      channel = args[:__channel].is_a?(String) ? args[:__channel] : ""
      channel = channel.strip
      return "exec is restricted to internal channels" if channel.empty? || !INTERNAL_CHANNELS.include?(channel)
    end

    bool_arg = ->(key) { v = args[key]; v == true || v == "true" }
    is_pty = bool_arg.call(:pty)
    is_background = bool_arg.call(:background)

    if is_pty && windows?
      return "PTY is not supported on Windows. Use background=true without pty."
    end

    cwd = @working_dir.to_s
    wd = args[:cwd]
    if wd.is_a?(String) && !wd.empty?
      if @restrict_to_workspace && !cwd.empty?
        begin
          cwd = FsSandbox.validate_path(wd, workspace: @working_dir, restrict: true,
                                          patterns: @allowed_path_patterns)
        rescue FsSandbox::Error => e
          return "Command blocked by safety guard (#{e.message})"
        end
      else
        cwd = wd
      end
    end
    cwd = Dir.pwd if cwd.empty?

    guard_error = guard_command(command, cwd)
    return guard_error unless guard_error.empty?

    # Re-resolve symlinks immediately before execution (TOCTOU shrink).
    if @restrict_to_workspace && !@working_dir.to_s.empty? && cwd != @working_dir
      resolved =
        begin
          File.realpath(cwd)
        rescue SystemCallError => e
          return "Command blocked by safety guard (path resolution failed: #{e.message})"
        end
      if FsSandbox.allowed_path?(resolved, @allowed_path_patterns)
        cwd = resolved
      else
        ws_abs = File.expand_path(@working_dir)
        ws_real =
          begin
            File.realpath(ws_abs)
          rescue SystemCallError
            ws_abs
          end
        rel =
          begin
            Pathname.new(resolved).relative_path_from(Pathname.new(ws_real)).to_s
          rescue ArgumentError
            nil
          end
        return "Command blocked by safety guard (working directory escaped workspace)" if rel.nil? || !FsSandbox.local?(rel)

        cwd = resolved
      end
    end

    is_background ? run_background(command, cwd, is_pty) : run_sync(command, cwd)
  end

  def run_sync(command, cwd)
    out = +"".b
    err = +"".b
    status = nil
    timed_out = false

    begin
      spawn_opts = { pgroup: true }
      spawn_opts[:chdir] = cwd unless cwd.empty?
      Open3.popen3("sh", "-c", command, spawn_opts) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        pid = wait_thr.pid
        readers = [[stdout, out], [stderr, err]].map do |io, buf|
          Thread.new do
            begin
              loop { buf << io.readpartial(65_536) }
            rescue EOFError, IOError
              nil
            end
          end
        end

        if @timeout
          unless wait_thr.join(@timeout)
            timed_out = true
            # terminateProcessTree: SIGKILL the process group, then the shell.
            begin
              Process.kill("KILL", -pid)
            rescue SystemCallError
              nil
            end
            begin
              Process.kill("KILL", pid)
            rescue SystemCallError
              nil
            end
            unless wait_thr.join(2)
              begin
                Process.kill("KILL", pid)
              rescue SystemCallError
                nil
              end
              wait_thr.join
            end
          end
        else
          wait_thr.join
        end
        status = wait_thr.value
        readers.each(&:join)
      end
    rescue SystemCallError => e
      return "failed to start command: #{e.message}"
    end

    output = out
    output += "\nSTDERR:\n" + err unless err.empty?

    if timed_out
      msg = "Command timed out after #{go_duration(@timeout)}"
      msg += "\n\nPartial output before timeout:\n" + output unless output.empty?
      return msg.force_encoding(Encoding::UTF_8).scrub
    end

    if status && !status.success?
      output +=
        if status.signaled? # upstream reports exit code -1 for signals
          "\n\n[Command exited with code -1] (killed by signal)"
        else
          "\n\n[Command exited with code #{status.exitstatus}]"
        end
    end

    output = +"(no output)" if output.empty?
    if output.bytesize > MAX_SYNC_OUTPUT
      output = output.byteslice(0, MAX_SYNC_OUTPUT) +
               "\n... (truncated, #{output.bytesize - MAX_SYNC_OUTPUT} more chars)"
    end
    output.force_encoding(Encoding::UTF_8).scrub
  end

  def run_background(command, cwd, pty_enabled)
    session_id = @session_manager.generate_session_id
    session = ExecSession.new(id: session_id, command: command, pty: pty_enabled)

    if pty_enabled
      begin
        spawn_opts = {}
        spawn_opts[:chdir] = cwd unless cwd.empty?
        master, _slave, pid = PTY.spawn("sh", "-c", command, spawn_opts)
      rescue Errno::ENOENT, Errno::ENOTDIR => e
        return "failed to start command: #{e.message}"
      rescue StandardError => e
        return "failed to create PTY: #{e.message}"
      end
      session.pid = pid
      session.pty_master = master
      @session_manager.add(session)

      Thread.new do # waiter
        begin
          Process.wait(pid)
          session.mark_done($?&.exitstatus || -1)
        rescue Errno::ECHILD
          session.mark_done(-1)
        rescue StandardError
          session.mark_error
        end
      end

      Thread.new do # reader (PTY mode auto-detects the application cursor-keys mode)
        loop do
          begin
            data = master.readpartial(4096)
          rescue EOFError, IOError, Errno::EIO
            break
          end
          mode = ExecKeys.detect_pty_key_mode(data)
          session.pty_key_mode = mode if mode != ExecKeys::MODE_NOT_FOUND && mode != session.pty_key_mode
          session.append_output(data)
        end
      end
    else
      begin
        spawn_opts = { pgroup: true }
        spawn_opts[:chdir] = cwd unless cwd.empty?
        stdin, stdout, stderr, wait_thr = Open3.popen3("sh", "-c", command, spawn_opts)
      rescue SystemCallError => e
        return "failed to start command: #{e.message}"
      end
      session.pid = wait_thr.pid
      session.stdin_writer = stdin
      @session_manager.add(session)

      Thread.new do # upstream reads stdout fully, then stderr, then closes stdin and waits
        [stdout, stderr].each do |io|
          begin
            loop { session.append_output(io.readpartial(4096)) }
          rescue EOFError, IOError
            nil
          end
        end
        begin
          stdin.close
        rescue IOError
          nil
        end
        status = wait_thr.value
        session.mark_done(status.exitstatus || -1)
      end
    end

    exec_response(session_id: session_id, status: "running")
  end

  # --- session actions ----------------------------------------------------------

  def execute_list
    exec_response(sessions: @session_manager.list)
  end

  def execute_poll(args)
    session_id = args[:sessionId]
    return "sessionId is required" unless session_id.is_a?(String)

    session = find_session(session_id)
    return "session not found: #{session_id}" unless session

    exec_response(session_id: session_id, status: session.status, exit_code: session.exit_code)
  end

  def execute_read(args)
    session_id = args[:sessionId]
    return "sessionId is required" unless session_id.is_a?(String)

    session = find_session(session_id)
    return "session not found: #{session_id}" unless session

    exec_response(session_id: session_id, status: session.status,
                  output: session.read.force_encoding(Encoding::UTF_8).scrub)
  end

  def execute_write(args)
    session_id = args[:sessionId]
    return "sessionId is required" unless session_id.is_a?(String)

    data = args[:data]
    return "data is required" unless args.key?(:data) && data.is_a?(String)

    session = find_session(session_id)
    return "session not found: #{session_id}" unless session
    return "process already exited with code #{session.exit_code}" if session.done?

    begin
      session.write(data)
    rescue ExecSession::DoneError
      return "process already exited with code #{session.exit_code}"
    rescue ExecSession::NoStdinError => e
      return "failed to write to session: #{e.message}"
    rescue SystemCallError, IOError => e
      return "failed to write to session: #{e.message}"
    end

    exec_response(session_id: session_id, status: session.status)
  end

  def execute_kill(args)
    session_id = args[:sessionId]
    return "sessionId is required" unless session_id.is_a?(String)

    session = find_session(session_id)
    return "session not found: #{session_id}" unless session
    return "process already exited with code #{session.exit_code}" if session.done?

    begin
      session.kill
    rescue ExecSession::DoneError
      return "process already exited with code #{session.exit_code}"
    rescue Errno::ESRCH
      return "failed to kill session: session not found"
    rescue StandardError => e
      return "failed to kill session: #{e.message}"
    end
    @session_manager.remove(session_id)

    exec_response(session_id: session_id, status: "done")
  end

  def execute_send_keys(args)
    session_id = args[:sessionId]
    return "sessionId is required" unless session_id.is_a?(String)

    keys_str = args[:keys]
    return "keys must be a string" unless keys_str.is_a?(String)
    return "keys cannot be empty" if keys_str.empty?

    keys = keys_str.split(",").map(&:strip).reject(&:empty?)
    return "keys cannot be empty" if keys.empty?

    session = find_session(session_id)
    return "session not found: #{session_id}" unless session

    data =
      begin
        ExecKeys.encode_sequence(keys, session.pty_key_mode)
      rescue ArgumentError => e
        return "invalid key: #{e.message}"
      end

    return "process already exited with code #{session.exit_code}" if session.done?

    begin
      session.write(data)
    rescue ExecSession::DoneError
      return "process already exited with code #{session.exit_code}"
    rescue ExecSession::NoStdinError, SystemCallError, IOError => e
      return "failed to send keys: #{e.message}"
    end

    exec_response(session_id: session_id, status: "running", output: "Sent keys: [#{keys.join(' ')}]")
  end

  # --- guardCommand -------------------------------------------------------------

  def guard_command(command, cwd)
    cmd = command.strip
    lower = cmd.downcase

    # Deny patterns always apply, even when a custom allow rule matches (#3079).
    @deny_patterns.each do |pattern|
      return "Command blocked by safety guard (dangerous pattern detected)" if pattern.match?(lower)
    end

    if @allow_patterns.any? && !command_matches_allow?(lower)
      return "Command blocked by safety guard (not in allowlist)"
    end

    return "" unless @restrict_to_workspace

    if TRAVERSAL_PATTERN.match?(cmd)
      return "Command blocked by safety guard (path traversal detected)"
    end

    cwd_path = File.expand_path(cwd)

    matches = []
    cmd.scan(ABSOLUTE_PATH_PATTERN) { matches << Regexp.last_match }
    matches.each do |match|
      raw = match[0]
      start = match.begin(0)

      # Web URL path components ("https://host/x" captures "//host/x").
      if raw.start_with?("//") && start.positive?
        before = cmd[0...start]
        next if WEB_SCHEMES.any? { |scheme| before.end_with?(scheme) }
      end

      # Scheme-less URL paths ("wttr.in/Beijing"): skip when the token before
      # the "/" looks like a domain AND does not exist locally (#2965).
      if start.positive? && raw.start_with?("/")
        j = start - 1
        j -= 1 while j >= 0 && !TOKEN_BOUNDARIES.include?(cmd[j])
        token = cmd[(j + 1)...start]
        next if looks_like_domain?(token) && !local_path_exists?(cwd, token)
      end

      path_text = command_path_text_from_match(cmd, start, match.end(0))
      path = Pathname.new(path_text).absolute? ? FsSandbox.clean(path_text) : File.expand_path(File.join(cwd_path, path_text))

      resolved =
        begin
          File.realpath(path)
        rescue SystemCallError
          path
        end

      next if SAFE_PATHS.include?(resolved)
      next if FsSandbox.allowed_path?(resolved, @allowed_path_patterns)

      rel =
        begin
          Pathname.new(resolved).relative_path_from(Pathname.new(cwd_path)).to_s
        rescue ArgumentError
          next
        end
      # Upstream quirk kept: HasPrefix("..") also catches siblings named "..foo".
      return "Command blocked by safety guard (path outside working dir)" if rel.start_with?("..")
    end

    ""
  end

  def command_matches_allow?(lower)
    (@allow_patterns + @custom_allow_patterns).any? { |pattern| pattern.match?(lower) }
  end

  # commandPathTextFromMatch port: expand a regex match to the meaningful path
  # text — whole token, the value of --flag=/path, or the raw absolute path.
  def command_path_text_from_match(cmd, start, match_end)
    raw = cmd[start...match_end]
    return raw if !raw.start_with?("/") || unix_absolute_path_match_start?(cmd, start)

    token_start = start
    token_start -= 1 while token_start.positive? && !TOKEN_BOUNDARIES.include?(cmd[token_start - 1])
    token_end = match_end
    token_end += 1 while token_end < cmd.length && !TOKEN_BOUNDARIES.include?(cmd[token_end])
    prefix = cmd[token_start...start]

    if (eq = prefix.index("="))
      return cmd[(token_start + eq + 1)...token_end]
    end
    return raw if prefix.start_with?("-")

    cmd[token_start...token_end]
  end

  # True when a "/" match actually starts an absolute path token (not the
  # separator inside "skills/foo.py" or an attached "-I/path" flag).
  def unix_absolute_path_match_start?(cmd, idx)
    return true if idx <= 0

    prev = cmd[idx - 1]
    return true if TOKEN_BOUNDARIES.include?(prev) || ["=", ",", "(", "[", "{"].include?(prev)

    j = idx - 1
    j -= 1 while j >= 0 && !TOKEN_BOUNDARIES.include?(cmd[j])
    prefix = cmd[(j + 1)...idx]
    prefix.start_with?("-") && !prefix.include?("=")
  end

  def looks_like_domain?(token)
    return false if token.nil? || token.length < 3 || !token.include?(".")
    return false unless token[0].match?(/[a-zA-Z0-9]/)

    ext = token.split(".").last
    !COMMON_FILE_EXTENSIONS.include?(ext.downcase)
  end

  def local_path_exists?(cwd, token)
    !File.lstat(File.join(cwd, token)).nil?
  rescue SystemCallError
    false
  end

  # --- helpers ------------------------------------------------------------------

  def find_session(id)
    @session_manager.get(id)
  rescue ExecSessionManager::NotFound
    nil
  end

  # ExecResponse port, honoring Go's omitempty tags (exitCode 0, empty output
  # and empty session lists are omitted).
  def exec_response(session_id: nil, status: nil, exit_code: 0, output: nil, sessions: nil)
    resp = {}
    resp["sessionId"] = session_id if session_id && !session_id.empty?
    resp["status"] = status if status && !status.empty?
    resp["exitCode"] = exit_code if exit_code != 0
    resp["output"] = output if output && !output.empty?
    resp["sessions"] = sessions if sessions && !sessions.empty?
    JSON.generate(resp)
  end

  # Go's time.Duration String() for whole seconds: 5s, 1m0s, 1h0m0s.
  def go_duration(seconds)
    h = seconds / 3600
    m = (seconds % 3600) / 60
    s = seconds % 60
    out = +""
    out << "#{h}h" if h.positive?
    out << "#{m}m" if m.positive? || h.positive?
    out << "#{s}s"
  end

  def compile_custom(pattern, kind)
    Regexp.new(pattern)
  rescue RegexpError, TypeError => e
    # Upstream fails tool construction, and the agent logs + skips exec.
    raise ArgumentError, "invalid custom #{kind} pattern #{pattern.inspect}: #{e.message}"
  end

  def windows? = Gem.win_platform?
end
