# frozen_string_literal: true

require "json"
require_relative "linux_ioctl"

# serial — picoclaw `pkg/tools/hardware/serial.go` + serial_unix.go.
# list (glob /dev/ttyS*|ttyUSB*|ttyACM*|ttyAMA*|rfcomm*|tty.*|cu.*), read
# (poll with 100ms slices up to timeout), write (confirm-gated). Port names
# are whitelist-validated; config goes through termios ioctls.
class Serial < Brute::Tool
  MAX_PAYLOAD = 4096
  PORT_PATTERN = %r{\A(?:/dev/)?(?:ttyS\d+|ttyUSB\d+|ttyACM\d+|ttyAMA\d+|rfcomm\d+|tty\.[A-Za-z0-9._-]+|cu\.[A-Za-z0-9._-]+)\z}.freeze
  UNIX_BAUDS = [50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400].freeze

  description "Interact with host serial ports. Actions: list (enumerate ports), read (receive " \
              "bytes), write (send bytes with explicit confirmation). Supports Linux, macOS, and Windows."
  params({
    "type" => "object",
    "properties" => {
      "action" => { "type" => "string", "enum" => %w[list read write], "description" => "Action to perform: list available serial ports, read bytes from a port, or write bytes to a port." },
      "port" => { "type" => "string", "description" => "Serial port path or name, for example /dev/ttyUSB0, /dev/cu.usbserial-0001, or COM3. Required for read/write." },
      "baud" => { "type" => "integer", "description" => "Baud rate. Default: 115200. Linux/macOS currently support standard termios rates up to 230400; Windows accepts configured rates up to 4000000." },
      "data_bits" => { "type" => "integer", "description" => "Data bits. Supported values: 5, 6, 7, 8. Default: 8." },
      "parity" => { "type" => "string", "enum" => %w[none even odd], "description" => "Parity mode. Default: none." },
      "stop_bits" => { "type" => "integer", "description" => "Stop bits. Supported values: 1, 2. Default: 1." },
      "timeout_ms" => { "type" => "integer", "description" => "Read/write timeout in milliseconds. Default: 1000." },
      "length" => { "type" => "integer", "description" => "Number of bytes to read. Required for read. Range: 1-4096." },
      "data" => { "type" => "array", "items" => { "type" => "integer" }, "description" => "Bytes to write, each in range 0-255. Required for write unless text is provided." },
      "text" => { "type" => "string", "description" => "UTF-8 text to write. Required for write if data is omitted." },
      "confirm" => { "type" => "boolean", "description" => "Must be true for write operations." },
    },
    "required" => ["action"],
  })

  # port_normalizer: test seam (a PTY path fails the upstream whitelist).
  def initialize(port_normalizer: nil, opener: nil)
    @port_normalizer = port_normalizer
    @opener = opener
  end

  def name = "serial"

  def execute(action: nil, **args)
    case action
    when "list" then list
    when "read" then read(args)
    when "write" then write(args)
    when nil, "" then "action is required"
    else "unknown action: #{action} (valid: list, read, write)"
    end
  rescue StandardError => e
    warn("serial crashed: #{e.class}: #{e.message}")
    e.message
  end

  private

  def list
    ports = []
    %w[/dev/ttyS* /dev/ttyUSB* /dev/ttyACM* /dev/ttyAMA* /dev/rfcomm* /dev/tty.* /dev/cu.*].each do |pattern|
      Dir.glob(pattern).sort.each do |path|
        next if File.directory?(path)

        ports << { "name" => File.basename(path), "path" => path }
      end
    end
    ports.uniq! { |p| p["path"] }
    ports.sort_by! { |p| p["path"] }
    return "No serial ports found on this host." if ports.empty?

    JSON.pretty_generate({ "ports" => ports, "count" => ports.size })
  end

  def normalize_port(port)
    trimmed = port.to_s.strip
    return nil, "port is required (for example /dev/ttyUSB0, /dev/cu.usbserial-0001, or COM3)" if trimmed.empty?

    if @port_normalizer
      normalized = @port_normalizer.call(trimmed)
      return normalized ? [normalized, nil] : [nil, "invalid serial port: expected a safe Unix device name such as /dev/ttyUSB0 or /dev/cu.usbserial-0001"]
    end

    unless trimmed.match?(PORT_PATTERN)
      return nil, "invalid serial port: expected a safe Unix device name such as /dev/ttyUSB0 or /dev/cu.usbserial-0001"
    end

    [trimmed.start_with?("/dev/") ? trimmed : "/dev/#{trimmed}", nil]
  end

  def parse_config(args)
    port, err = normalize_port(args[:port])
    return [nil, err] if err

    cfg = { port: port, baud: 115200, data_bits: 8, parity: "none", stop_bits: 1 }

    cfg[:baud] = args[:baud].to_i if args[:baud].is_a?(Numeric)
    if cfg[:baud] < 50 || cfg[:baud] > 4_000_000
      return [nil, "baud must be between 50 and 4000000"]
    end
    unless UNIX_BAUDS.include?(cfg[:baud])
      return [nil, "unsupported baud rate on this platform: #{cfg[:baud]} (supported up to 230400)"]
    end

    cfg[:data_bits] = args[:data_bits].to_i if args[:data_bits].is_a?(Numeric)
    return [nil, "data_bits must be one of 5, 6, 7, or 8"] unless [5, 6, 7, 8].include?(cfg[:data_bits])

    if args[:parity].is_a?(String) && !args[:parity].strip.empty?
      cfg[:parity] = args[:parity].strip.downcase
    end
    return [nil, 'parity must be one of "none", "even", or "odd"'] unless %w[none even odd].include?(cfg[:parity])

    cfg[:stop_bits] = args[:stop_bits].to_i if args[:stop_bits].is_a?(Numeric)
    return [nil, "stop_bits must be 1 or 2"] unless [1, 2].include?(cfg[:stop_bits])

    timeout = 1000
    timeout = args[:timeout_ms].to_i if args[:timeout_ms].is_a?(Numeric)
    return [nil, "timeout_ms must be between 1 and 60000"] if timeout < 1 || timeout > 60_000
    cfg[:timeout_ms] = timeout

    [cfg, nil]
  end

  def parse_payload(args)
    if args[:text].is_a?(String) && !args[:text].empty?
      return [nil, "text must be valid UTF-8"] unless args[:text].valid_encoding?
      return [nil, "text payload too large: maximum #{MAX_PAYLOAD} bytes"] if args[:text].bytesize > MAX_PAYLOAD

      return [args[:text], nil]
    end

    raw = args[:data]
    return [nil, "write requires either text or data"] unless raw.is_a?(Array) && !raw.empty?
    return [nil, "data too long: maximum #{MAX_PAYLOAD} bytes"] if raw.size > MAX_PAYLOAD

    bytes = +""
    raw.each_with_index do |v, i|
      return [nil, "data[#{i}] is not a valid byte value"] unless v.is_a?(Numeric)
      return [nil, "data[#{i}] is not an integer byte value"] if v.is_a?(Float) && v != v.truncate
      return [nil, "data[#{i}] = #{v.to_i} is out of byte range (0-255)"] if v.to_i.negative? || v.to_i > 255

      bytes << v.to_i
    end
    [bytes, nil]
  end

  def open_port(cfg)
    io =
      if @opener
        @opener.call(cfg[:port])
      else
        File.open(cfg[:port], File::RDWR | File::NOCTTY | File::NONBLOCK)
      end
    LinuxIoctl.configure_serial(io, baud: cfg[:baud], data_bits: cfg[:data_bits],
                                  parity: cfg[:parity], stop_bits: cfg[:stop_bits])
    io
  end

  def read(args)
    cfg, err = parse_config(args)
    return err if err

    length = args[:length].is_a?(Numeric) ? args[:length].to_i : 0
    return "length is required for read (1-#{MAX_PAYLOAD})" if length < 1 || length > MAX_PAYLOAD

    data = +""
    deadline = Time.now + cfg[:timeout_ms] / 1000.0
    io =
      begin
        open_port(cfg)
      rescue StandardError => e
        return "serial read failed on #{cfg[:port]}: #{e.message}"
      end

    begin
      while data.bytesize < length
        remaining = deadline - Time.now
        break if remaining <= 0

        ready = IO.select([io], [], [], [remaining, 0.1].min)
        next unless ready

        begin
          data << io.read_nonblock(length - data.bytesize)
        rescue IO::WaitReadable
          next
        rescue EOFError
          break
        end
      end
    ensure
      io.close
    end

    JSON.pretty_generate(payload_json("read", cfg, data))
  end

  def write(args)
    return "write operations require confirm: true. Please confirm with the user before sending bytes to a serial device." unless args[:confirm] == true

    cfg, err = parse_config(args)
    return err if err

    payload, err = parse_payload(args)
    return err if err

    io =
      begin
        open_port(cfg)
      rescue StandardError => e
        return "serial write failed on #{cfg[:port]}: #{e.message}"
      end

    written = 0
    deadline = Time.now + cfg[:timeout_ms] / 1000.0
    begin
      while written < payload.bytesize
        remaining = deadline - Time.now
        break if remaining <= 0

        ready = IO.select([], [io], [], [remaining, 0.1].min)
        next unless ready

        begin
          written += io.write_nonblock(payload[written..])
        rescue IO::WaitWritable
          next
        end
      end
    ensure
      io.close
    end

    JSON.pretty_generate(payload_json("write", cfg, payload).merge("written" => written))
  end

  def payload_json(action, cfg, data)
    bytes = data.bytes
    summary = {
      "action" => action,
      "port" => cfg[:port],
      "baud" => cfg[:baud],
      "data_bits" => cfg[:data_bits],
      "parity" => cfg[:parity],
      "stop_bits" => cfg[:stop_bits],
      "timeout_ms" => cfg[:timeout_ms],
      "payload" => {
        "length" => bytes.size,
        "bytes" => bytes,
        "hex" => bytes.map { |b| format("0x%02x", b) },
      }.merge(data.valid_encoding? ? { "text" => data } : {}),
    }
    summary
  end
end
