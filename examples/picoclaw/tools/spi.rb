# frozen_string_literal: true

require "json"
require_relative "linux_ioctl"

# spi — picoclaw `pkg/tools/hardware/spi.go` + spi_linux.go. spidev ioctls on
# /dev/spidev* (Linux only): list (glob), transfer (full-duplex,
# confirm-gated), read (sends zeros). Device id guard: ^\d+\.\d+$.
class SPI < Brute::Tool
  description "Interact with SPI bus devices for high-speed peripheral communication. Actions: " \
              "list (find SPI devices), transfer (full-duplex send/receive), read (receive bytes). Linux only."
  params({
    "type" => "object",
    "properties" => {
      "action" => { "type" => "string", "enum" => %w[list transfer read], "description" => "Action to perform: list (find available SPI devices), transfer (full-duplex send/receive), read (receive bytes by sending zeros)" },
      "device" => { "type" => "string", "description" => "SPI device identifier (e.g. \"2.0\" for /dev/spidev2.0). Required for transfer/read." },
      "speed" => { "type" => "integer", "description" => "SPI clock speed in Hz. Default: 1000000 (1 MHz)." },
      "mode" => { "type" => "integer", "description" => "SPI mode (0-3). Default: 0. Mode sets CPOL and CPHA: 0=0,0 1=0,1 2=1,0 3=1,1." },
      "bits" => { "type" => "integer", "description" => "Bits per word. Default: 8." },
      "data" => { "type" => "array", "items" => { "type" => "integer" }, "description" => "Bytes to send (0-255 each). Required for transfer action." },
      "length" => { "type" => "integer", "description" => "Number of bytes to read (1-4096). Required for read action." },
      "confirm" => { "type" => "boolean", "description" => "Must be true for transfer operations. Safety guard to prevent accidental writes." },
    },
    "required" => ["action"],
  })

  def name = "spi"

  def execute(action: nil, **args)
    unless RbConfig::CONFIG["host_os"].include?("linux")
      return "SPI is only supported on Linux. This tool requires /dev/spidev* device files."
    end

    case action
    when "list" then list
    when "transfer" then transfer(args)
    when "read" then read_device(args)
    when nil, "" then "action is required"
    else "unknown action: #{action} (valid: list, transfer, read)"
    end
  rescue StandardError => e
    warn("spi crashed: #{e.class}: #{e.message}")
    e.message
  end

  private

  def list
    matches = Dir.glob("/dev/spidev*").sort
    if matches.empty?
      return "No SPI devices found. You may need to:\n1. Enable SPI in device tree\n2. Configure pinmux for your board (see hardware skill)\n3. Check that spidev module is loaded"
    end

    devices = matches.filter_map do |path|
      (m = path.match(%r{/dev/spidev(\d+\.\d+)})) && { "path" => path, "device" => m[1] }
    end
    "Found #{devices.size} SPI device(s):\n#{JSON.pretty_generate(devices)}"
  end

  def parse_args(args)
    dev = args[:device]
    return [nil, "device is required (e.g. \"2.0\" for /dev/spidev2.0)"] unless dev.is_a?(String) && !dev.empty?
    return [nil, "invalid device identifier: must be in format \"X.Y\" (e.g. \"2.0\")"] unless dev.match?(/\A\d+\.\d+\z/)

    speed = 1_000_000
    if (s = args[:speed]).is_a?(Numeric)
      return [nil, "speed must be between 1 Hz and 125 MHz"] if s < 1 || s > 125_000_000

      speed = s.to_i
    end

    mode = 0
    if (m = args[:mode]).is_a?(Numeric)
      return [nil, "mode must be 0-3"] if m.to_i.negative? || m.to_i > 3

      mode = m.to_i
    end

    bits = 8
    if (b = args[:bits]).is_a?(Numeric)
      return [nil, "bits must be between 1 and 32"] if b.to_i < 1 || b.to_i > 32

      bits = b.to_i
    end

    [[dev, speed, mode, bits], nil]
  end

  def configure(dev, mode, bits, speed)
    path = "/dev/spidev#{dev}"
    io =
      begin
        File.open(path, File::RDWR)
      rescue SystemCallError => e
        raise "failed to open #{path}: #{e.message} (check permissions and spidev module)"
      end

    if (errno = LinuxIoctl.spi_set_u8(io, LinuxIoctl::SPI_IOC_WR_MODE, mode)) != 0
      io.close
      raise "failed to set SPI mode #{mode}: errno #{errno}"
    end
    if (errno = LinuxIoctl.spi_set_u8(io, LinuxIoctl::SPI_IOC_WR_BITS_PER_WORD, bits)) != 0
      io.close
      raise "failed to set bits per word #{bits}: errno #{errno}"
    end
    if (errno = LinuxIoctl.spi_set_u32(io, LinuxIoctl::SPI_IOC_WR_MAX_SPEED_HZ, speed)) != 0
      io.close
      raise "failed to set SPI speed #{speed} Hz: errno #{errno}"
    end
    io
  end

  def spi_transfer(io, tx, length, speed, bits)
    tx_ptr = LinuxIoctl.ptr(length)
    rx_ptr = LinuxIoctl.ptr(length)
    tx_ptr[0, length] = tx
    errno = LinuxIoctl.spi_transfer(io, tx_ptr, rx_ptr, length, speed, bits)
    raise "SPI transfer failed: errno #{errno}" if errno != 0

    rx_ptr[0, length]
  end

  def transfer(args)
    return "transfer operations require confirm: true. Please confirm with the user before sending data to SPI devices." unless args[:confirm] == true

    (dev, speed, mode, bits), err = parse_args(args)
    return err if err

    raw = args[:data]
    return "data is required for transfer (array of byte values 0-255)" unless raw.is_a?(Array) && !raw.empty?
    return "data too long: maximum 4096 bytes per SPI transfer" if raw.size > 4096

    tx = +""
    raw.each_with_index do |v, i|
      return "data[#{i}] is not a valid byte value" unless v.is_a?(Numeric)
      return "data[#{i}] = #{v.to_i} is out of byte range (0-255)" if v.to_i.negative? || v.to_i > 255

      tx << v.to_i
    end

    io = configure(dev, mode, bits, speed)
    received = spi_transfer(io, tx, tx.bytesize, speed, bits)
    io.close

    bytes = received.bytes
    JSON.pretty_generate(
      "device" => "/dev/spidev#{dev}",
      "sent" => tx.bytesize,
      "received" => bytes,
      "hex" => bytes.map { |b| format("0x%02x", b) },
    )
  rescue StandardError => e
    io&.close
    e.message
  end

  def read_device(args)
    (dev, speed, mode, bits), err = parse_args(args)
    return err if err

    length = args[:length].is_a?(Numeric) ? args[:length].to_i : 0
    return "length is required for read (1-4096)" if length < 1 || length > 4096

    io = configure(dev, mode, bits, speed)
    received = spi_transfer(io, "\0" * length, length, speed, bits)
    io.close

    bytes = received.bytes
    JSON.pretty_generate(
      "device" => "/dev/spidev#{dev}",
      "bytes" => bytes,
      "hex" => bytes.map { |b| format("0x%02x", b) },
      "length" => bytes.size,
    )
  rescue StandardError => e
    io&.close
    e.message
  end
end
