---
name: attach-image
description: Load an on-disk image (PNG, JPEG, GIF, WebP) into the model's context as a viewable attachment so the model can directly SEE it — for screenshots, diagrams, charts, photos, or scanned pages. Requires a vision-capable model.
---

# Attach Image

Load on-disk images into the model's context as multimodal attachments —
the image is sent to the model the same way a pasted image is, so the model
can actually look at it. Call directly from IRuby:

    require "attach_image"
    AttachImage.run("screenshot.png", "diagram.jpg")

## API

- `AttachImage.run(*paths)` — validates and attaches each image; returns a
  confirmation string. Caps: source <= 20 MB and <= 36 MP; emitted
  attachment <= 350_000 base64 chars and <= 1200 px; JPEG quality ladder
  82/72/60/48/36; transparency flattened on #888888. Over-cap images are
  re-encoded through ImageMagick (`magick` must be on PATH); images within
  caps attach as-is.

## When to use this

- The user points at an image file and wants you to look at it.
- You need to read text, a chart, a diagram, or a layout from an image.
- A screenshot needs visual interpretation.

## When NOT to use this

For *programmatic* work on an image — measuring pixels, cropping, resizing,
computing a hash, comparing files byte-by-byte — open it in the kernel with a
library instead. That path does not put the image in the model's context.

## Notes

- The vision gate: when BRUTE_MODEL is set and matches no known vision
  family, calls raise a "does not support vision" error you can relay.
- Every path is validated before anything is emitted — a failure never
  leaves a partial subset attached.

## When NOT to use this

For *programmatic* work on an image — measuring pixels, cropping, resizing,
comparing bytes — open it in the kernel with a library instead; that path
does not spend model context.
