# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "socket"
require "tmpdir"

require_relative "jupyter"

module PrimeAgent
  # Spawns and drives an IRuby kernel over ZeroMQ — a Ruby port of
  # prime-agent's KernelManager (packages/coding-agent/src/core/kernel/
  # index.ts), adapted to iruby's quirks (see references/iruby):
  #
  #  - The host allocates the ports and writes the connection file: iruby
  #    never writes port-0 resolutions back (its ffi adapter discards the
  #    ephemeral port), so `free_port` picks real ones up front.
  #  - Readiness is the iopub `status: starting` message; a
  #    `kernel_info_request` probe doubles as the shell round-trip check.
  #  - There is no control channel: `shutdown_request` goes on the shell
  #    socket, and interrupts don't exist (the OS process must be signalled).
  #  - Executions are serialized through a mutex; completion is detected via
  #    iopub `status: idle` keyed on the request's msg_id (exactly like
  #    prime-agent); the shell `execute_reply` is drained afterwards.
  #
  # The transport is omq (https://github.com/zeromq/omq.rb) — a pure-Ruby
  # ZMTP stack: no libzmq/FFI on the host side, and its sockets are
  # fiber-aware, so receives inside brute's Async tool barrier yield the
  # fiber instead of blocking the thread. (The spawned iruby kernel keeps
  # using its own ffi-rzmq/libzmq internally — that's the kernel's affair.)
  #
  # `omq` is required lazily inside #start so this file loads in any
  # environment (specs exercise the pure parts without a kernel).
  class KernelManager
    PROTOCOL_USERNAME = "prime-agent"
    DEFAULT_MAX_OUTPUT_CHARS = 65_536
    READY_TIMEOUT_SECONDS = 30
    IOPUB_SUBSCRIBE_DELAY = 0.05

    class Error < StandardError; end

    # One execution's outcome. `status` is "ok" or "error"; `error` carries
    # { "ename", "evalue", "traceback" } when the cell raised.
    Result = Data.define(:stdout, :stderr, :result, :status, :error, :duration_ms)

    # Collects one cell's streamed output with prime-agent's cap semantics
    # (kernel/index.ts:1055-1119, 1139-1161): a stream buffer stops growing
    # at the cap and earns a truncation notice; the final execute_result is
    # capped at finish.
    class Output
      TRUNCATION_NOTICE = "[... output truncated at %<max>d chars ...]"

      attr_writer :result

      def initialize(max_chars)
        @max_chars = max_chars
        @stdout = +""
        @stderr = +""
        @stdout_truncated = false
        @stderr_truncated = false
        @result = nil
        @error = nil
      end

      def add_stream(name, text)
        buffer = name == "stderr" ? @stderr : @stdout
        truncated = name == "stderr" ? @stderr_truncated : @stdout_truncated
        return if buffer.length >= @max_chars

        buffer << text
        return unless buffer.length > @max_chars

        buffer.replace(buffer[0, @max_chars])
        name == "stderr" ? @stderr_truncated = true : @stdout_truncated = true
        truncated
      end

      def set_error(ename, evalue, traceback)
        @error = {
          "ename" => ename.to_s,
          "evalue" => evalue.to_s,
          "traceback" => Array(traceback),
        }
      end

      def finish(status:, duration_ms:)
        stdout = @stdout.dup
        stderr = @stderr.dup
        stdout += "\n#{format(TRUNCATION_NOTICE, max: @max_chars)}" if @stdout_truncated
        stderr += "\n#{format(TRUNCATION_NOTICE, max: @max_chars)}" if @stderr_truncated
        result = @result
        if result && result.length > @max_chars
          result = "#{result[0, @max_chars]}\n#{format(TRUNCATION_NOTICE, max: @max_chars)}"
        end
        Result.new(
          stdout: stdout,
          stderr: stderr,
          result: result,
          status: @error ? "error" : status,
          error: @error,
          duration_ms: duration_ms,
        )
      end
    end

    attr_reader :connection

    def initialize(cwd:, env: {}, username: PROTOCOL_USERNAME)
      @cwd = cwd
      @env = env
      @username = username
      @session = SecureRandom.uuid
      @execute_mutex = Mutex.new
      @pid = nil
      @reaped = false
    end

    # Spawn the kernel, connect the sockets, and prove the shell round-trip
    # with a kernel_info probe. On any failure the process is cleaned up.
    #
    # An at_exit backstop guarantees cleanup on unhandled exceptions —
    # otherwise the kernel child would be orphaned.
    def start
      require "omq"
      @tmpdir = Dir.mktmpdir("prime-agent-iruby-")
      @connection = self.class.write_connection_file(@tmpdir)
      spawn_kernel
      connect_sockets
      probe_ready
      self
    rescue StandardError
      shutdown
      raise
    ensure
      unless @at_exit_registered
        @at_exit_registered = true
        at_exit { shutdown }
      end
    end

    def running?
      !@pid.nil? && process_alive?
    end

    def connection_path
      File.join(@tmpdir, "connection.json")
    end

    # Execute a cell and return a Result. Serialized: iruby evaluates one
    # cell at a time, and brute's tool middleware may run tool calls
    # concurrently, so the mutex keeps the Jupyter shell request/reply
    # discipline.
    def execute(code, max_output_chars: DEFAULT_MAX_OUTPUT_CHARS)
      @execute_mutex.synchronize { execute_locked(code, max_output_chars) }
    end

    # Best-effort graceful stop: shutdown_request on shell, then TERM, then
    # KILL. Idempotent.
    def shutdown
      stop_kernel_process
      [@shell, @iopub].compact.each { |socket| close_socket(socket) }
      @shell = @iopub = nil
      FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
      @tmpdir = nil
      @pid = nil
      nil
    end

    # ------------------------------------------------------------------
    # Connection file + ports (host-allocated — see class comment)
    # ------------------------------------------------------------------

    def self.write_connection_file(dir)
      info = {
        "transport" => "tcp",
        "ip" => "127.0.0.1",
        "signature_scheme" => "hmac-sha256",
        "key" => SecureRandom.hex(16),
        "shell_port" => free_port,
        "iopub_port" => free_port,
        "stdin_port" => free_port,
        "control_port" => free_port,
        "hb_port" => free_port,
        "kernel_name" => "ruby",
      }
      path = File.join(dir, "connection.json")
      File.write(path, "#{JSON.pretty_generate(info)}\n")
      File.chmod(0o600, path)
      info
    end

    def self.free_port
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      port
    end

    private

    def spawn_kernel
      executable =
        begin
          Gem.bin_path("iruby", "iruby")
        rescue Gem::Exception
          "iruby"
        end
      @log_path = File.join(@tmpdir, "kernel.log")
      argv = [executable, "kernel", "-f", connection_path, "--log=#{@log_path}"]
      @pid = spawn(@env.merge("NO_COLOR" => "1"), *argv,
                   chdir: @cwd, in: :close, out: @log_path, err: [:child, :out])
    rescue Errno::ENOENT
      raise Error, "could not spawn `iruby` — is the iruby gem installed in this bundle?"
    end

    def connect_sockets
      @shell = OMQ::DEALER.connect(endpoint(@connection["shell_port"]))
      @shell.read_timeout = 0.25
      @shell.write_timeout = 5

      @iopub = OMQ::SUB.connect(endpoint(@connection["iopub_port"]))
      @iopub.read_timeout = 0.25
      @iopub.subscribe("")
      sleep(IOPUB_SUBSCRIBE_DELAY) # ZMQ slow-joiner guard
    end

    def endpoint(port)
      "tcp://127.0.0.1:#{port}"
    end

    def probe_ready
      deadline = monotonic + READY_TIMEOUT_SECONDS
      until monotonic > deadline
        unless process_alive?
          raise Error, "IRuby kernel exited during boot.\n#{kernel_log_tail}"
        end

        message = Jupyter::Framing.build_message("kernel_info_request", {},
                                                 session: @session, username: @username)
        send_frames(@shell, Jupyter::Framing.encode(message, @connection["key"]))
        reply = recv_matching(@shell, message[:header]["msg_id"], 0.5)
        return true if reply && reply.dig("header", "msg_type") == "kernel_info_reply"
      end
      raise Error,
            "IRuby kernel did not answer kernel_info_request within " \
            "#{READY_TIMEOUT_SECONDS}s.\n#{kernel_log_tail}"
    end

    def execute_locked(code, max_output_chars)
      started = monotonic
      message = Jupyter::Framing.build_message(
        "execute_request",
        {
          "code" => code,
          "silent" => false,
          "store_history" => true,
          "user_expressions" => {},
          "allow_stdin" => false,
          "stop_on_error" => true,
        },
        session: @session, username: @username,
      )
      msg_id = message[:header]["msg_id"]
      output = Output.new(max_output_chars)
      send_frames(@shell, Jupyter::Framing.encode(message, @connection["key"]))

      loop do
        frames = recv_frames(@iopub)
        if frames.nil?
          unless process_alive?
            raise Error, "IRuby kernel died mid-execution.\n#{kernel_log_tail}"
          end

          next
        end
        incoming = Jupyter::Framing.decode(frames) or next
        next unless incoming.dig("parent_header", "msg_id") == msg_id

        case incoming.dig("header", "msg_type")
        when "stream"
          output.add_stream(incoming["content"]["name"], incoming["content"]["text"].to_s)
        when "execute_result"
          data = incoming["content"]["data"] || {}
          output.result = data["text/plain"] if data["text/plain"]
        when "error"
          content = incoming["content"]
          output.set_error(content["ename"], content["evalue"], content["traceback"])
        when "status"
          break if incoming["content"]["execution_state"] == "idle"
        end
      end

      reply = recv_matching(@shell, msg_id, 2)
      status = reply && reply.dig("content", "status") == "error" ? "error" : "ok"
      output.finish(status: status, duration_ms: ((monotonic - started) * 1000).round)
    end

    # Receive until a message with this parent msg_id arrives or the timeout
    # (seconds) elapses. Stale frames (other parents) are discarded.
    def recv_matching(socket, msg_id, timeout)
      deadline = monotonic + timeout
      while monotonic < deadline
        frames = recv_frames(socket)
        next if frames.nil?

        message = Jupyter::Framing.decode(frames)
        next if message.nil?

        return message if message.dig("parent_header", "msg_id") == msg_id
      end
      nil
    end

    def send_frames(socket, frames)
      socket.send(frames)
    rescue IO::TimeoutError
      raise Error, "zmq send timed out"
    end

    # Returns the multipart message as an array of (frozen) parts, or nil on
    # receive timeout (the socket's read_timeout governs the poll cadence).
    def recv_frames(socket)
      socket.receive
    rescue IO::TimeoutError
      nil
    end

    def stop_kernel_process
      return unless @pid && process_alive?

      begin
        if @shell
          message = Jupyter::Framing.build_message("shutdown_request", { "restart" => false },
                                                   session: @session, username: @username)
          send_frames(@shell, Jupyter::Framing.encode(message, @connection["key"]))
          recv_matching(@shell, message[:header]["msg_id"], 2)
        end
      rescue StandardError
        nil
      end
      terminate_process
    end

    def terminate_process
      begin
        Process.kill("TERM", @pid)
      rescue Errno::ESRCH
        return
      end
      30.times do
        break unless process_alive?

        sleep 0.1
      end
      if process_alive?
        begin
          Process.kill("KILL", @pid)
        rescue Errno::ESRCH
          nil
        end
      end
      begin
        Process.waitpid(@pid)
      rescue Errno::ECHILD
        nil
      end
      @reaped = true
    end

    def process_alive?
      return false if @pid.nil? || @reaped

      @reaped = !Process.waitpid(@pid, Process::WNOHANG).nil?
      !@reaped
    rescue Errno::ECHILD
      @reaped = true
      false
    end

    def close_socket(socket)
      socket.close
    rescue StandardError
      nil
    end

    def kernel_log_tail
      return "" unless @log_path && File.exist?(@log_path)

      File.read(@log_path).last(1024)
    rescue StandardError
      ""
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/kernel_manager" do
  describe "connection file" do
    it "writes the Jupyter connection schema with real ports and 0600 perms" do
      Dir.mktmpdir do |dir|
        info = PrimeAgent::KernelManager.write_connection_file(dir)

        %w[transport ip signature_scheme key shell_port iopub_port stdin_port control_port hb_port]
          .each { |key| info.key?(key).should.be.true }
        info["transport"].should == "tcp"
        info["signature_scheme"].should == "hmac-sha256"
        info["key"].length.should == 32
        %w[shell_port iopub_port stdin_port control_port hb_port].each do |port|
          info[port].should.be.kind_of Integer
          info[port].should.be > 0
        end

        path = File.join(dir, "connection.json")
        (File.stat(path).mode & 0o777).should == 0o600
        JSON.parse(File.read(path))["key"].should == info["key"]
      end
    end

    it "allocates distinct free ports" do
      ports = Array.new(10) { PrimeAgent::KernelManager.free_port }
      ports.uniq.length.should == ports.length
      ports.each { |port| port.should.be > 1024 }
    end
  end

  describe "output collection (prime-agent cap semantics)" do
    def output(max = 10)
      PrimeAgent::KernelManager::Output.new(max)
    end

    it "collects streams and result" do
      out = output(100)
      out.add_stream("stdout", "hello")
      out.add_stream("stderr", "oops")
      out.result = "42"
      result = out.finish(status: "ok", duration_ms: 5)
      result.stdout.should == "hello"
      result.stderr.should == "oops"
      result.result.should == "42"
      result.status.should == "ok"
    end

    it "caps a stream at the max and adds the truncation notice" do
      out = output(10)
      out.add_stream("stdout", "0123456789ABCDEF") # 16 > 10
      out.add_stream("stdout", "dropped")          # at cap → dropped entirely
      result = out.finish(status: "ok", duration_ms: 0)
      result.stdout.should.start_with "0123456789"
      result.stdout.should.include "[... output truncated at 10 chars ...]"
      result.stdout.should.not.include "dropped"
    end

    it "keeps appending while under the cap" do
      out = output(10)
      out.add_stream("stdout", "01234")
      out.add_stream("stdout", "56789") # exactly at cap, no truncation
      out.finish(status: "ok", duration_ms: 0).stdout.should == "0123456789"
    end

    it "caps the final result with a notice" do
      out = output(5)
      out.result = "123456789"
      result = out.finish(status: "ok", duration_ms: 0)
      result.result.should.include "12345"
      result.result.should.include "truncated"
    end

    it "forces status error when an error was collected" do
      out = output(100)
      out.set_error("RuntimeError", "boom", ["line1"])
      result = out.finish(status: "ok", duration_ms: 0)
      result.status.should == "error"
      result.error["ename"].should == "RuntimeError"
      result.error["traceback"].should == ["line1"]
    end
  end
end
