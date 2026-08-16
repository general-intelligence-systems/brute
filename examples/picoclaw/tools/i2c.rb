# frozen_string_literal: true

require "json"
require_relative "linux_ioctl"

# i2c — picoclaw `pkg/tools/hardware/i2c.go` + i2c_linux.go. SMBus ioctls on
# /dev/i2c-* (Linux only): detect (glob buses), scan (i2cdetect MODE_AUTO
# strategy: Quick Write, Read Byte in the EEPROM ranges), read/write
# (confirm-gated). Path-injection guard: bus must be ^\d+$.
class I2C < Brute::Tool
  description "Interact with I2C bus devices for reading sensors and controlling peripherals. " \
              "Actions: detect (list buses), scan (find devices on a bus), read (read bytes from " \
              "device), write (send bytes to device). Linux only."
  params({
    "type" => "object",
    "properties" => {
      "action" => { "type" => "string", "enum" => %w[detect scan read write], "description" => "Action to perform: detect (list available I2C buses), scan (find devices on a bus), read (read bytes from a device), write (send bytes to a device)" },
      "bus" => { "type" => "string", "description" => "I2C bus number (e.g. \"1\" for /dev/i2c-1). Required for scan/read/write." },
      "address" => { "type" => "integer", "description" => "7-bit I2C device address (0x03-0x77). Required for read/write." },
      "register" => { "type" => "integer", "description" => "Register address to read from or write to. If set, sends register byte before read/write." },
      "data" => { "type" => "array", "items" => { "type" => "integer" }, "description" => "Bytes to write (0-255 each). Required for write action." },
      "length" => { "type" => "integer", "description" => "Number of bytes to read (1-256). Default: 1. Used with read action." },
      "confirm" => { "type" => "boolean", "description" => "Must be true for write operations. Safety guard to prevent accidental writes." },
    },
    "required" => ["action"],
  })

  def name = "i2c"

  def execute(action: nil, **args)
    unless linux?
      return "I2C is only supported on Linux. This tool requires /dev/i2c-* device files."
    end

    case action
    when "detect" then detect
    when "scan" then scan(args)
    when "read" then read_device(args)
    when "write" then write_device(args)
    when nil, "" then "action is required"
    else "unknown action: #{action} (valid: detect, scan, read, write)"
    end
  rescue StandardError => e
    warn("i2c crashed: #{e.class}: #{e.message}")
    e.message
  end

  private

  def linux? = RbConfig::CONFIG["host_os"].include?("linux")

  def detect
    return "I2C is only supported on Linux. This tool requires /dev/i2c-* device files." unless linux?

    matches = Dir.glob("/dev/i2c-*").sort
    if matches.empty?
      return "No I2C buses found. You may need to:\n1. Load the i2c-dev module: modprobe i2c-dev\n2. Check that I2C is enabled in device tree\n3. Configure pinmux for your board (see hardware skill)"
    end

    buses = matches.filter_map do |path|
      (m = path.match(%r{/dev/i2c-(\d+)})) && { "path" => path, "bus" => m[1] }
    end
    "Found #{buses.size} I2C bus(es):\n#{JSON.pretty_generate(buses)}"
  end

  def parse_bus(args)
    bus = args[:bus]
    return [nil, "bus is required (e.g. \"1\" for /dev/i2c-1)"] unless bus.is_a?(String) && !bus.empty?
    return [nil, "invalid bus identifier: must be a number (e.g. \"1\")"] unless bus.match?(/\A\d+\z/)

    [bus, nil]
  end

  def parse_address(args)
    addr = args[:address]
    return [nil, "address is required (e.g. 0x38 for AHT20)"] unless addr.is_a?(Numeric)

    addr = addr.to_i
    return [nil, "address must be in valid 7-bit range (0x03-0x77)"] if addr < 0x03 || addr > 0x77

    [addr, nil]
  end

  def open_bus(bus)
    dev = "/dev/i2c-#{bus}"
    File.open(dev, File::RDWR)
  rescue SystemCallError => e
    raise "failed to open #{dev}: #{e.message} (check permissions and i2c-dev module)"
  end

  # SMBus Quick Write for most addresses, Read Byte in the EEPROM ranges
  # (0x30-0x37, 0x50-0x5F — Quick Write can corrupt AT24RF08 chips).
  def smbus_probe(io, addr, has_quick)
    use_read_byte = (0x30..0x37).cover?(addr) || (0x50..0x5F).cover?(addr)

    if !use_read_byte && has_quick
      LinuxIoctl.smbus_ioctl(io, LinuxIoctl::I2C_SMBUS_WRITE, 0, LinuxIoctl::I2C_SMBUS_QUICK, LinuxIoctl.ptr(0)).zero?
    else
      data = LinuxIoctl.ptr(34)
      LinuxIoctl.smbus_ioctl(io, LinuxIoctl::I2C_SMBUS_READ, 0, LinuxIoctl::I2C_SMBUS_BYTE, data).zero?
    end
  end

  def scan(args)
    bus, err = parse_bus(args)
    return err if err
    return "I2C is only supported on Linux. This tool requires /dev/i2c-* device files." unless linux?

    io = open_bus(bus)
    funcs = LinuxIoctl.i2c_funcs(io)
    has_quick = (funcs & LinuxIoctl::I2C_FUNC_SMBUS_QUICK) != 0
    has_read_byte = (funcs & LinuxIoctl::I2C_FUNC_SMBUS_READ_BYTE) != 0
    unless has_quick || has_read_byte
      io.close
      return "I2C adapter /dev/i2c-#{bus} supports neither SMBus Quick nor Read Byte — cannot probe safely"
    end

    found = []
    (0x08..0x77).each do |addr|
      errno = LinuxIoctl.i2c_set_slave(io, addr)
      if errno != 0
        found << { "address" => format("0x%02x", addr), "status" => "busy (in use by kernel driver)" } if errno == 16 # EBUSY
        next
      end
      found << { "address" => format("0x%02x", addr) } if smbus_probe(io, addr, has_quick)
    end
    io.close

    return "No devices found on /dev/i2c-#{bus}. Check wiring and pull-up resistors." if found.empty?

    "Scan of /dev/i2c-#{bus}:\n#{JSON.pretty_generate({ "bus" => "/dev/i2c-#{bus}", "devices" => found, "count" => found.size })}"
  rescue StandardError => e
    io&.close
    e.message
  end

  def read_device(args)
    bus, err = parse_bus(args)
    return err if err

    addr, err = parse_address(args)
    return err if err

    length = args[:length].is_a?(Numeric) ? args[:length].to_i : 1
    return "length must be between 1 and 256" if length < 1 || length > 256

    io = open_bus(bus)
    errno = LinuxIoctl.i2c_set_slave(io, addr)
    if errno != 0
      io.close
      return format("failed to set I2C address 0x%02x: errno %d", addr, errno)
    end

    if (reg = args[:register]).is_a?(Numeric)
      reg = reg.to_i
      return "register must be between 0x00 and 0xFF" if reg.negative? || reg > 255

      begin
        io.write([reg].pack("C"))
      rescue SystemCallError => e
        io.close
        return format("failed to write register 0x%02x: %s", reg, e.message)
      end
    end

    data = io.read(length).to_s.b
    io.close

    bytes = data.bytes
    JSON.pretty_generate(
      "bus" => "/dev/i2c-#{bus}",
      "address" => format("0x%02x", addr),
      "bytes" => bytes,
      "hex" => bytes.map { |b| format("0x%02x", b) },
      "length" => bytes.size,
    )
  rescue StandardError => e
    io&.close
    e.message
  end

  def write_device(args)
    return "write operations require confirm: true. Please confirm with the user before writing to I2C devices, as incorrect writes can misconfigure hardware." unless args[:confirm] == true

    bus, err = parse_bus(args)
    return err if err

    addr, err = parse_address(args)
    return err if err

    raw = args[:data]
    return "data is required for write (array of byte values 0-255)" unless raw.is_a?(Array) && !raw.empty?
    return "data too long: maximum 256 bytes per I2C transaction" if raw.size > 256

    data = +""
    if (reg = args[:register]).is_a?(Numeric)
      reg = reg.to_i
      return "register must be between 0x00 and 0xFF" if reg.negative? || reg > 255

      data << reg
    end
    raw.each_with_index do |v, i|
      return "data[#{i}] is not a valid byte value" unless v.is_a?(Numeric)
      return "data[#{i}] = #{v.to_i} is out of byte range (0-255)" if v.to_i.negative? || v.to_i > 255

      data << v.to_i
    end

    io = open_bus(bus)
    errno = LinuxIoctl.i2c_set_slave(io, addr)
    if errno != 0
      io.close
      return format("failed to set I2C address 0x%02x: errno %d", addr, errno)
    end

    written = io.write(data)
    io.close
    format("Wrote %d byte(s) to device 0x%02x on /dev/i2c-%s", written, addr, bus)
  rescue StandardError => e
    io&.close
    e.message
  end
end
