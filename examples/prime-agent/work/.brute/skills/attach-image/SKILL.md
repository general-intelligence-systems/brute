---
name: attach-image
description: Load an on-disk image (PNG, JPEG, GIF, WebP) into the model's context as a viewable attachment so the model can directly SEE it — for screenshots, diagrams, charts, photos, or scanned pages. Requires a vision-capable model.
---

# Attach Image

SCAFFOLD — no-op port of prime-agent `packages/coding-agent/skills/attach-image`.
The function below exists but returns a "not implemented" error payload; see
FEATURES.md (S3) for the fill-in contract.

Load on-disk images into the model's context as multimodal attachments —
the image is sent to the model the same way a pasted image is, so the model
can actually look at it. Call directly from IRuby:

    require "attach_image"
    AttachImage.run("screenshot.png", "diagram.jpg")

## API

- `AttachImage.run(*paths)` — validates and attaches each image; returns a
  confirmation string. Caps upstream: source <= 20 MB and <= 36 MP; emitted
  attachment <= 350_000 base64 chars and <= 1200 px; JPEG quality ladder
  82/72/60/48/36; transparency flattened on #888888.

## When NOT to use this

For *programmatic* work on an image — measuring pixels, cropping, resizing,
comparing bytes — open it in the kernel with a library instead; that path
does not spend model context.
