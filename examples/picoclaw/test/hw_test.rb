# frozen_string_literal: true

# Hardware tools: validation contracts + a live PTY round-trip for serial.
# Device ioctls (i2c/spi SMBus/transfers) are exercised on real hardware;
# here we cover everything testable on a dev box.

require "fileutils"
require "tmpdir"
require "json"
require "pty"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "brute"

ROOT = File.expand_path("..", __dir__)
%w[linux_ioctl i2c spi serial].each { |f| require_relative "#{ROOT}/tools/#{f}" }

$failures = []
$count = 0

def test(name)
  $count += 1
  yield
  puts "  ok  #{name}"
rescue StandardError, ScriptError => e
  $failures << [name, e]
  puts "FAIL  #{name}: #{e.class}: #{e.message}"
  puts e.backtrace.first(6).map { |l| "      #{l}" }
end

def assert(cond, msg = "expected truthy")
  raise msg unless cond
end

def assert_equal(exp, act)
  raise("expected #{exp.inspect}, got #{act.inspect}") unless exp == act
end

def assert_includes(hay, needle)
  raise("expected to include #{needle.inspect}:\n#{hay}") unless hay.include?(needle)
end

# --- i2c -----------------------------------------------------------------------

test "i2c: validation contract + confirm gate + empty-host detect" do
  tool = I2C.new
  assert_equal "action is required", tool.call({})
  assert_equal "unknown action: poke (valid: detect, scan, read, write)", tool.call("action" => "poke")

  detect = tool.call("action" => "detect")
  assert(detect.include?("No I2C buses found") || detect.include?("Found"), detect)

  assert_equal "bus is required (e.g. \"1\" for /dev/i2c-1)", tool.call("action" => "scan")
  assert_equal "invalid bus identifier: must be a number (e.g. \"1\")", tool.call("action" => "scan", "bus" => "../0")

  assert_equal "address is required (e.g. 0x38 for AHT20)", tool.call("action" => "read", "bus" => "1")
  assert_equal "address must be in valid 7-bit range (0x03-0x77)",
               tool.call("action" => "read", "bus" => "1", "address" => 0x01)
  assert_equal "length must be between 1 and 256",
               tool.call("action" => "read", "bus" => "1", "address" => 0x40, "length" => 0)

  assert_includes tool.call("action" => "write", "bus" => "1", "address" => 0x40, "data" => [1]),
                  "write operations require confirm: true"
  assert_equal "data is required for write (array of byte values 0-255)",
               tool.call("action" => "write", "bus" => "1", "address" => 0x40, "confirm" => true)
  assert_equal "data[0] = 300 is out of byte range (0-255)",
               tool.call("action" => "write", "bus" => "1", "address" => 0x40, "data" => [300], "confirm" => true)

  # no such device on this host → open failure surfaces the errno message
  out = tool.call("action" => "read", "bus" => "99", "address" => 0x40)
  assert_includes out, "failed to open /dev/i2c-99"
end

# --- spi -----------------------------------------------------------------------

test "spi: validation contract + confirm gate + empty-host list" do
  tool = SPI.new
  assert_equal "action is required", tool.call({})
  assert_equal "unknown action: x (valid: list, transfer, read)", tool.call("action" => "x")

  list = tool.call("action" => "list")
  assert(list.include?("No SPI devices found") || list.include?("Found"), list)

  assert_equal "device is required (e.g. \"2.0\" for /dev/spidev2.0)", tool.call("action" => "read")
  assert_equal "invalid device identifier: must be in format \"X.Y\" (e.g. \"2.0\")",
               tool.call("action" => "read", "device" => "2")
  assert_equal "length is required for read (1-4096)",
               tool.call("action" => "read", "device" => "2.0", "length" => 0)
  assert_equal "mode must be 0-3", tool.call("action" => "read", "device" => "2.0", "length" => 1, "mode" => 4)
  assert_equal "bits must be between 1 and 32", tool.call("action" => "read", "device" => "2.0", "length" => 1, "bits" => 33)
  assert_equal "speed must be between 1 Hz and 125 MHz",
               tool.call("action" => "read", "device" => "2.0", "length" => 1, "speed" => 0)

  assert_includes tool.call("action" => "transfer", "device" => "2.0", "data" => [1]),
                  "transfer operations require confirm: true"
  assert_equal "data is required for transfer (array of byte values 0-255)",
               tool.call("action" => "transfer", "device" => "2.0", "confirm" => true)

  out = tool.call("action" => "read", "device" => "9.9", "length" => 1)
  assert_includes out, "failed to open /dev/spidev9.9"
end

# --- serial --------------------------------------------------------------------

test "serial: validation contract + port whitelist" do
  tool = Serial.new
  assert_equal "action is required", tool.call({})
  assert_equal "unknown action: x (valid: list, read, write)", tool.call("action" => "x")

  assert_equal "port is required (for example /dev/ttyUSB0, /dev/cu.usbserial-0001, or COM3)",
               tool.call("action" => "read", "length" => 1)
  assert_includes tool.call("action" => "read", "port" => "/etc/passwd", "length" => 1), "invalid serial port"
  assert_equal "length is required for read (1-4096)", tool.call("action" => "read", "port" => "/dev/ttyUSB0", "length" => 0)
  assert_equal "baud must be between 50 and 4000000",
               tool.call("action" => "read", "port" => "/dev/ttyUSB0", "length" => 1, "baud" => 10)
  assert_equal "unsupported baud rate on this platform: 1000 (supported up to 230400)",
               tool.call("action" => "read", "port" => "/dev/ttyUSB0", "length" => 1, "baud" => 1000)
  assert_equal "data_bits must be one of 5, 6, 7, or 8",
               tool.call("action" => "read", "port" => "/dev/ttyUSB0", "length" => 1, "data_bits" => 9)
  assert_equal "stop_bits must be 1 or 2",
               tool.call("action" => "read", "port" => "/dev/ttyUSB0", "length" => 1, "stop_bits" => 3)
  assert_equal "timeout_ms must be between 1 and 60000",
               tool.call("action" => "read", "port" => "/dev/ttyUSB0", "length" => 1, "timeout_ms" => 0)

  assert_includes tool.call("action" => "write", "port" => "/dev/ttyUSB0", "text" => "x"),
                  "write operations require confirm: true"
  assert_equal "write requires either text or data",
               tool.call("action" => "write", "port" => "/dev/ttyUSB0", "confirm" => true)
  assert_equal "data[0] is not an integer byte value",
               tool.call("action" => "write", "port" => "/dev/ttyUSB0", "data" => [1.5], "confirm" => true)

  list = tool.call("action" => "list")
  assert(list.include?("No serial ports found") || list.include?("ports"), list)
end

test "serial: read/write round-trip over a PTY pair" do
  master, slave = PTY.open
  tool = Serial.new(port_normalizer: ->(p) { p }, opener: ->(path) { File.open(path, File::RDWR | File::NONBLOCK) })

  # tool write → master reads
  out = tool.call("action" => "write", "port" => slave.path, "text" => "AT\r\n", "confirm" => true)
  assert_includes out, '"written": 4'
  sleep 0.05
  assert_equal "AT\r\n", master.readpartial(64).sub("\r\n", "\r\n")

  # master writes → tool read
  master.write("OK\r")
  sleep 0.05
  result = JSON.parse(tool.call("action" => "read", "port" => slave.path, "length" => 3, "timeout_ms" => 500))
  assert_equal "OK\r", result["payload"]["text"]

  # read timeout returns the bytes received so far (none)
  result = JSON.parse(tool.call("action" => "read", "port" => slave.path, "length" => 5, "timeout_ms" => 200))
  assert_equal 0, result["payload"]["length"]
ensure
  master&.close
  slave&.close
end

puts "\n#{$count} tests, #{$failures.size} failures"
exit($failures.empty? ? 0 : 1)
