# frozen_string_literal: true

require "securerandom"

# Port of picoclaw's pkg/tools/session.go: background exec sessions.
#
# A session owns a process (pipe- or PTY-backed), a 1MB-capped output buffer
# (destructive-drain reads), and a 30-minutes-after-done garbage collector
# running every 5 minutes on the manager's cleaner thread.

class ExecSession
  MAX_OUTPUT_BUFFER_SIZE = 1 * 1024 * 1024
  OUTPUT_TRUNCATE_MARKER = "\n... [output truncated, exceeded 1MB]\n"

  class DoneError < StandardError; end
  class NoStdinError < StandardError
    def message = "no stdin available"
  end

  attr_reader :id, :command, :start_time
  attr_accessor :pid, :pty_master, :stdin_writer

  def initialize(id:, command:, pty:, background: true)
    @id = id
    @command = command
    @pty = pty
    @background = background
    @start_time = Time.now.to_i
    @status = "running"
    @exit_code = 0
    @output = +"".b
    @output_truncated = false
    @pty_key_mode = ExecKeys::MODE_CSI
    @mutex = Mutex.new
  end

  def pty? = @pty

  def append_output(data)
    @mutex.synchronize do
      if @output.bytesize >= MAX_OUTPUT_BUFFER_SIZE
        unless @output_truncated
          @output << OUTPUT_TRUNCATE_MARKER
          @output_truncated = true
        end
      else
        @output << data
      end
    end
  end

  # Destructive: returns the buffered output and resets the buffer.
  def read
    @mutex.synchronize do
      return +"".b if @output.empty?

      data = @output
      @output = +"".b
      data
    end
  end

  def status = @mutex.synchronize { @status }
  def exit_code = @mutex.synchronize { @exit_code }
  def pty_key_mode = @mutex.synchronize { @pty_key_mode }
  def pty_key_mode=(mode)
    @mutex.synchronize { @pty_key_mode = mode }
  end
  def done? = %w[done exited].include?(status)

  def mark_done(code) = @mutex.synchronize { @exit_code = code; @status = "done" }
  def mark_error = @mutex.synchronize { @status = "error" }

  def write(data)
    writer =
      @mutex.synchronize do
        raise DoneError if @status != "running"

        if @pty && @pty_master
          @pty_master
        elsif @stdin_writer
          @stdin_writer
        else
          raise NoStdinError
        end
      end
    writer.write(data)
  end

  # killProcessGroup port: SIGKILL the process group, fall back to the pid.
  def kill
    @mutex.synchronize do
      raise DoneError if @status != "running"
      raise Errno::ESRCH if @pid.to_i <= 0

      begin
        Process.kill("KILL", -@pid)
      rescue SystemCallError
        begin
          Process.kill("KILL", @pid)
        rescue SystemCallError
          nil
        end
      end
      @status = "done"
      @exit_code = -1
    end
    true
  end

  def to_info
    { "id" => @id, "command" => @command, "status" => status, "pid" => @pid, "startedAt" => @start_time }
  end
end

# Named-key → escape sequence maps + the PtyKeyMode machinery (from shell.go).
module ExecKeys
  MODE_CSI = 0
  MODE_SS3 = 1
  MODE_NOT_FOUND = 255

  KEY_MAP = {
    "enter" => "\r", "return" => "\r", "tab" => "\t", "escape" => "\e", "esc" => "\e",
    "space" => " ", "backspace" => "\x7f", "bspace" => "\x7f",
    "up" => "\e[A", "down" => "\e[B", "right" => "\e[C", "left" => "\e[D",
    "home" => "\e[1~", "end" => "\e[4~",
    "pageup" => "\e[5~", "pgup" => "\e[5~", "pagedown" => "\e[6~", "pgdn" => "\e[6~",
    "insert" => "\e[2~", "ic" => "\e[2~", "delete" => "\e[3~", "del" => "\e[3~", "dc" => "\e[3~",
    "btab" => "\e[Z",
    "f1" => "\eOP", "f2" => "\eOQ", "f3" => "\eOR", "f4" => "\eOS",
    "f5" => "\e[15~", "f6" => "\e[17~", "f7" => "\e[18~", "f8" => "\e[19~",
    "f9" => "\e[20~", "f10" => "\e[21~", "f11" => "\e[23~", "f12" => "\e[24~",
  }.freeze

  SS3_KEYS_MAP = {
    "up" => "\eOA", "down" => "\eOB", "right" => "\eOC", "left" => "\eOD",
    "home" => "\eOH", "end" => "\eOF",
  }.freeze

  SMKX = "\e[?1h".b
  RMKX = "\e[?1l".b

  module_function

  # smkx/rmkx detection: whichever sequence appears LAST in the chunk wins.
  def detect_pty_key_mode(raw)
    smkx = raw.rindex(SMKX)
    rmkx = raw.rindex(RMKX)
    return MODE_NOT_FOUND if smkx.nil? && rmkx.nil?

    (smkx || -1) > (rmkx || -1) ? MODE_SS3 : MODE_CSI
  end

  # encodeKeyToken port. Raises ArgumentError with the upstream messages.
  def encode_token(token, pty_key_mode)
    token = token.strip.downcase
    return "" if token.empty?

    if token.start_with?("c-", "ctrl-")
      char = token.start_with?("c-") ? token[2] : token[5]
      raise ArgumentError, "invalid ctrl key: #{token}" unless char && char.match?(/[a-z]/)

      return (char.ord & 0x1f).chr
    end

    if token.start_with?("m-", "alt-")
      char = token.start_with?("m-") ? token[2..] : token[4..]
      raise ArgumentError, "invalid alt key: #{token}" unless char&.length == 1

      return "\e#{char}"
    end

    if token.start_with?("s-", "shift-")
      key = token.start_with?("s-") ? token[2..] : token[6..]
      if (seq = KEY_MAP[key])
        return seq.length == 1 ? seq.upcase : seq
      end

      raise ArgumentError, "unknown key with shift: #{key}"
    end

    if pty_key_mode == MODE_SS3 && (seq = SS3_KEYS_MAP[token])
      return seq
    end
    return KEY_MAP[token] if KEY_MAP.key?(token)

    raise ArgumentError, "unknown key: #{token} (use write action for text input)"
  end

  def encode_sequence(tokens, pty_key_mode)
    tokens.map { |token| encode_token(token, pty_key_mode) }.join
  end
end

class ExecSessionManager
  class NotFound < StandardError; end

  def self.instance
    @instance ||= new
  end

  def initialize
    @sessions = {}
    @mutex = Mutex.new
    @stop = false
    # Cleaner thread: every 5 minutes drop sessions done for >30 minutes.
    @cleaner = Thread.new do
      loop do
        sleep 300
        break if @mutex.synchronize { @stop }

        cleanup_old_sessions
      end
    end
  end

  def stop
    @mutex.synchronize { @stop = true }
  end

  def cleanup_old_sessions
    cutoff = Time.now.to_i - 30 * 60
    @mutex.synchronize do
      @sessions.delete_if { |_, session| session.done? && session.start_time < cutoff }
    end
  end

  def add(session) = @mutex.synchronize { @sessions[session.id] = session }

  def get(id)
    @mutex.synchronize do
      session = @sessions[id]
      raise NotFound, "session not found" unless session

      session
    end
  end

  def remove(id) = @mutex.synchronize { @sessions.delete(id) }

  def list = @mutex.synchronize { @sessions.values.map(&:to_info) }

  def generate_session_id = SecureRandom.uuid[0, 8]
end
