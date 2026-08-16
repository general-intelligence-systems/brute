# frozen_string_literal: true

require "base64"
require "tmpdir"

# AttachImage — prime-agent bundled skill `attach-image` (FEATURES.md S3).
# Port of prime-agent
# `packages/coding-agent/skills/attach-image/src/attach_image/attach_image.py`:
# load on-disk images into the model's context as viewable attachments.
# Loaded into IRuby via require "attach_image".
#
# Port adaptations:
#  - dimension sniffing is pure Ruby (PNG IHDR, GIF header, JPEG SOF scan,
#    WebP VP8/VP8L/VP8X chunks) — no PIL;
#  - the re-encode path (over-cap images) shells out to `magick` with the
#    same scale-to-1200px + JPEG quality ladder (82/72/60/48/36) and 0.75x
#    downscale loop; within caps the bytes attach as-is, like upstream's
#    fast path;
#  - the vision gate checks BRUTE_MODEL against known vision families
#    (upstream asks the host model registry); unset BRUTE_MODEL passes.
module AttachImage
  ATTACHMENT_DISPLAY_MIME = "application/vnd.prime-agent.attachment+json"

  MAX_SOURCE_IMAGE_BYTES = 20_000_000
  MAX_SOURCE_IMAGE_PIXELS = 36_000_000
  MAX_ATTACHMENT_DATA_CHARS = 350_000
  MAX_ATTACHMENT_DIMENSION = 1200
  TRANSPARENCY_BACKGROUND = "#888888"
  JPEG_QUALITIES = [82, 72, 60, 48, 36].freeze

  VISION_PATTERN = /gpt-4o|gpt-4\.1|gpt-5|chatgpt|o[1-9]\b|claude|gemini|vision|vl-|llava|pixtral|qwen/i

  module_function

  # Load one or more on-disk images into the model's context as attachments.
  # Raises on empty input, missing files, unsupported/oversized images, and
  # non-vision models — same contract as upstream.
  def run(*paths)
    raise ArgumentError, "attach_image requires at least one image path" if paths.empty?

    model = ENV["BRUTE_MODEL"].to_s
    if !model.empty? && !model.match?(VISION_PATTERN)
      raise "#{model} does not support vision. " \
            "Tell the user to switch to a vision-capable model to load images into context."
    end

    validated = paths.map { |path| validate_image(path) }
    notes = []
    validated.each do |path, mime, size, dimensions|
      note = emit_attachment(path, mime, size, dimensions)
      notes << "#{path}: #{note}" if note
    end

    message = "Loaded #{validated.length} image(s) into context: #{paths.join(", ")}"
    unless notes.empty?
      message += "\nResized for efficient inline rendering/replay:\n- #{notes.join("\n- ")}"
    end
    message
  end

  # ------------------------------------------------------------------
  # Validation (_validate_image)
  # ------------------------------------------------------------------

  def validate_image(path)
    filepath = File.expand_path(path)
    raise Errno::ENOENT, "#{path} not found" unless File.file?(filepath)

    data = File.binread(filepath)
    if data.bytesize > MAX_SOURCE_IMAGE_BYTES
      raise ArgumentError, "#{path} is too large (#{data.bytesize} bytes > #{MAX_SOURCE_IMAGE_BYTES})"
    end

    mime = detect_image_mime(data)
    raise ArgumentError, "#{path} is not a supported image (PNG, JPEG, GIF, WebP)" unless mime

    dimensions = image_dimensions(data, mime)
    raise ArgumentError, "#{path} is not a readable supported image (PNG, JPEG, GIF, WebP)" unless dimensions

    if dimensions[0] * dimensions[1] > MAX_SOURCE_IMAGE_PIXELS
      raise ArgumentError, "#{path} has too many pixels (#{dimensions.join("x")} > #{MAX_SOURCE_IMAGE_PIXELS})"
    end

    [filepath, mime, data.bytesize, dimensions]
  end

  def detect_image_mime(data)
    return "image/png" if data.start_with?("\x89PNG\r\n\x1a\n".b)
    return "image/jpeg" if data.start_with?("\xff\xd8\xff".b)
    return "image/gif" if data.start_with?("GIF87a") || data.start_with?("GIF89a")
    return "image/webp" if data[0, 4] == "RIFF".b && data[8, 4] == "WEBP"

    nil
  end

  def image_dimensions(data, mime)
    case mime
    when "image/png"
      return nil unless data.bytesize >= 24 && data[12, 4] == "IHDR"

      data[16, 8].unpack("N2")
    when "image/gif"
      return nil unless data.bytesize >= 10

      data[6, 4].unpack("v2")
    when "image/jpeg" then jpeg_dimensions(data)
    when "image/webp" then webp_dimensions(data)
    end
  end

  def jpeg_dimensions(data)
    offset = 2 # past the SOI marker
    while offset < data.bytesize - 1
      offset += 1 while offset < data.bytesize && data.getbyte(offset) != 0xFF
      marker = data.getbyte(offset + 1)
      offset += 2
      next if marker.nil? || marker == 0xFF || (0xD0..0xD9).cover?(marker)

      length = data[offset, 2].unpack1("n")
      if (0xC0..0xCF).cover?(marker) && ![0xC4, 0xC8, 0xCC].include?(marker)
        height, width = data[offset + 3, 4].unpack("n2")
        return [width, height]
      end
      offset += length
    end
    nil
  end

  def webp_dimensions(data)
    chunk = data[12, 4]
    case chunk
    when "VP8X"
      return nil unless data.bytesize >= 30

      width = data[24, 3].unpack("C3").then { |b| b[0] | (b[1] << 8) | (b[2] << 16) } + 1
      height = data[27, 3].unpack("C3").then { |b| b[0] | (b[1] << 8) | (b[2] << 16) } + 1
      [width, height]
    when "VP8 "
      return nil unless data.bytesize >= 30 && data[23, 3] == "\x9d\x01\x2a".b

      width = data[26, 2].unpack1("v") & 0x3FFF
      height = data[28, 2].unpack1("v") & 0x3FFF
      [width, height]
    when "VP8L"
      return nil unless data.bytesize >= 25 && data.getbyte(21) == 0x2F

      bits = data[22, 4].unpack1("V")
      [(bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1]
    end
  end

  # ------------------------------------------------------------------
  # Resize + emit (_resize_image / _emit_attachment)
  # ------------------------------------------------------------------

  def emit_attachment(path, mime, size, dimensions)
    data_b64, emitted_mime, note = resize_image(path, mime, size, dimensions)
    emit_display(
      ATTACHMENT_DISPLAY_MIME => { "mime_type" => emitted_mime, "data" => data_b64, "path" => path },
      "text/plain" => "Loaded image into context: #{path}",
    ) # NOTE: one merged hash argument
    note
  end

  def resize_image(path, mime, size, dimensions)
    data = File.binread(path)
    encoded_chars = (data.bytesize * 8.0 / 6).ceil # _base64_chars without encoding

    if size <= MAX_ATTACHMENT_DATA_CHARS * 3 / 4 &&
       dimensions.max <= MAX_ATTACHMENT_DIMENSION &&
       encoded_chars <= MAX_ATTACHMENT_DATA_CHARS
      return [Base64.strict_encode64(data), mime, nil]
    end

    raise "attach_image needs ImageMagick (`magick`) to resize this image before loading it into context." unless magick?

    original_width, original_height = dimensions
    scale = [1.0, MAX_ATTACHMENT_DIMENSION.to_f / dimensions.max].min
    target_width = [1, (original_width * scale).round].max
    target_height = [1, (original_height * scale).round].max
    last = nil

    while target_width >= 1 && target_height >= 1
      JPEG_QUALITIES.each do |quality|
        candidate = magick_jpeg(path, target_width, target_height, quality)
        last = [candidate, target_width, target_height]
        encoded = Base64.strict_encode64(candidate)
        next unless encoded.length <= MAX_ATTACHMENT_DATA_CHARS

        note = "original #{original_width}x#{original_height}; attached " \
               "#{target_width}x#{target_height} JPEG at quality #{quality}"
        note += "; transparency flattened on #{TRANSPARENCY_BACKGROUND}" if %w[image/png image/gif image/webp].include?(mime)
        return [encoded, "image/jpeg", note]
      end

      next_width = [1, (target_width * 0.75).to_i].max
      next_height = [1, (target_height * 0.75).to_i].max
      break if next_width == target_width && next_height == target_height

      target_width, target_height = next_width, next_height
    end

    candidate, last_width, last_height = last
    raise ArgumentError,
          "#{path} could not be compressed below #{MAX_ATTACHMENT_DATA_CHARS / 1000}KB base64 payload " \
          "(smallest was #{Base64.strict_encode64(candidate).length / 1000}KB at #{last_width}x#{last_height})."
  end

  def magick?
    return @magick_available unless @magick_available.nil?

    @magick_available = system("magick", "-version", out: File::NULL, err: File::NULL) ? true : false
  end

  def magick_jpeg(path, width, height, quality)
    out = "#{Dir.mktmpdir}/attach-#{rand(1 << 32)}.jpg"
    ok = system(
      "magick", path,
      "-resize", "#{width}x#{height}",
      "-background", TRANSPARENCY_BACKGROUND, "-flatten",
      "-quality", quality.to_s, out,
      out: File::NULL, err: File::NULL,
    )
    raise "magick failed on #{path}" unless ok && File.exist?(out)

    File.binread(out)
  end

  # Best-effort display channel — identical to the edit skill's diff display;
  # a display failure must never break the cell.
  def emit_display(data)
    return unless defined?(IRuby::Kernel)

    IRuby::Kernel.instance.session.send(:publish, :display_data, data: data, metadata: {})
    nil
  rescue StandardError
    nil
  end
end
