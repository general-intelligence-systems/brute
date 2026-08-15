# frozen_string_literal: true

require "json"

# AttachImage — prime-agent bundled skill `attach-image`. SCAFFOLD: no-op
# (FEATURES.md S3). Port of prime-agent
# `packages/coding-agent/skills/attach-image/src/attach_image/attach_image.py`:
# load on-disk images into the model's context as viewable attachments.
# Loaded into IRuby via require "attach_image".
# Returns the scaffold error payload until filled in.
module AttachImage
  module_function

  # Attach one or more on-disk images (PNG, JPEG, GIF, WebP) to the model's
  # context. Fill-in: sniff mime, validate (<= 20 MB, <= 36 MP), re-encode
  # (<= 1200 px, <= 350_000 base64 chars, JPEG quality ladder 82/72/60/48/36,
  # transparency flattened on #888888) and emit the attachment display
  # payload through a kernel->host channel that lands as a multimodal
  # message. Needs a vision-capable model.
  def run(*paths)
    not_implemented("run")
  end

  def not_implemented(function)
    JSON.dump("error" => "not implemented", "skill" => "attach-image", "function" => function)
  end
end
