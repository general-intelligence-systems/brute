# frozen_string_literal: true

require "fiddle"

# LinuxIoctl — the shared kernel-ioctl layer for the hardware tools
# (i2c-dev SMBus, spidev, termios serial). Ruby passes String buffers to
# IO#ioctl as pointers; Fiddle::Pointer gives us raw addresses for struct
# pointer fields. All constants are the Linux kernel header values.
module LinuxIoctl
  # linux/i2c-dev.h, linux/i2c.h
  I2C_SLAVE = 0x0703
  I2C_FUNCS = 0x0705
  I2C_SMBUS = 0x0720
  I2C_FUNC_SMBUS_QUICK = 0x00010000
  I2C_FUNC_SMBUS_READ_BYTE = 0x00020000
  I2C_SMBUS_READ = 0
  I2C_SMBUS_WRITE = 1
  I2C_SMBUS_QUICK = 0
  I2C_SMBUS_BYTE = 1

  # linux/spi/spidev.h — _IOW('k', nr, size)
  SPI_IOC_WR_MODE = 0x40016B01
  SPI_IOC_WR_BITS_PER_WORD = 0x40016B03
  SPI_IOC_WR_MAX_SPEED_HZ = 0x40046B04
  SPI_IOC_MESSAGE_1 = 0x40206B00

  # asm-generic/termbits.h
  TCGETS = 0x5401
  TCSETS = 0x5402
  CREAD = 0x80
  CLOCAL = 0x800
  CSIZE = 0x30
  CS5 = 0x00
  CS6 = 0x10
  CS7 = 0x20
  CS8 = 0x30
  PARENB = 0x100
  PARODD = 0x200
  CSTOPB = 0x40
  VMIN = 6
  VTIME = 5

  BAUD_TO_B = {
    50 => 1, 75 => 2, 110 => 3, 134 => 4, 150 => 5, 200 => 6, 300 => 7,
    600 => 8, 1200 => 9, 1800 => 10, 2400 => 11, 4800 => 12, 9600 => 13,
    19200 => 14, 38400 => 15, 57600 => 0x1001, 115200 => 0x1002, 230400 => 0x1003,
  }.freeze

  # i2c_smbus_ioctl_data { u8 rw; u8 command; u32 size; ptr data } — 16 bytes.
  def self.smbus_ioctl(fd, read_write, command, size, data_ptr)
    args = [read_write, command, size, data_ptr.to_i].pack("CCxxVQ")
    fd.ioctl(I2C_SMBUS, args)
    0
  rescue SystemCallError => e
    e.errno
  end

  def self.i2c_set_slave(fd, addr)
    fd.ioctl(I2C_SLAVE, addr)
    0
  rescue SystemCallError => e
    e.errno
  end

  def self.i2c_funcs(fd)
    buf = "\0" * 8
    fd.ioctl(I2C_FUNCS, buf)
    buf.unpack1("Q")
  end

  def self.ptr(bytes = 34)
    Fiddle::Pointer.malloc(bytes)
  end

  # spi_ioc_transfer (32 bytes): tx u64, rx u64, len u32, speed u32,
  # delay u16, bits u8, cs_change u8, tx/rx_nbits u8, word_delay u8, pad u8.
  def self.spi_transfer(fd, tx_ptr, rx_ptr, length, speed, bits)
    struct = [tx_ptr.to_i, rx_ptr.to_i, length, speed, 0, bits, 0, 0, 0, 0, 0].pack("QQVVvCCCCC")
    fd.ioctl(SPI_IOC_MESSAGE_1, struct)
    0
  rescue SystemCallError => e
    e.errno
  end

  def self.spi_set_u8(fd, request, value)
    fd.ioctl(request, [value].pack("C"))
    0
  rescue SystemCallError => e
    e.errno
  end

  def self.spi_set_u32(fd, request, value)
    fd.ioctl(request, [value].pack("V"))
    0
  rescue SystemCallError => e
    e.errno
  end

  # Kernel struct termios (44 bytes): iflag/oflag/cflag/lflag u32, line u8,
  # cc[19] u8, ispeed/ospeed u32.
  def self.termios_get(io)
    buf = "\0" * 44
    io.ioctl(TCGETS, buf)
    buf
  end

  def self.termios_set(io, buf)
    io.ioctl(TCSETS, buf)
  end

  # Raw mode + config per picoclaw's configureUnixSerialPort.
  def self.configure_serial(io, baud:, data_bits:, parity:, stop_bits:)
    b = BAUD_TO_B[baud]
    raise "unsupported baud rate on this platform: #{baud}" unless b

    buf = termios_get(io)
    iflag = 0
    oflag = 0
    lflag = 0
    cflag = CREAD | CLOCAL
    cflag |= { 5 => CS5, 6 => CS6, 7 => CS7 }[data_bits] || CS8
    cflag |= PARENB if parity == "even"
    cflag |= PARENB | PARODD if parity == "odd"
    cflag |= CSTOPB if stop_bits == 2

    cc = buf[17, 19].bytes
    cc[VMIN] = 0
    cc[VTIME] = 0

    packed = [iflag, oflag, cflag, lflag].pack("V4") + buf[16, 1] + cc.pack("C19") + [b, b].pack("V2")
    termios_set(io, packed)
  end
end
