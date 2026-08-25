#!/usr/bin/env ruby
# frozen_string_literal: true

##
# Regenerates the API reference section of the docs site from the source.
#
#   ruby docs/bin/gen-reference.rb
#
# Writes Markdown pages into `docs/src/content/reference/` and the sidebar
# tree into `docs/src/generated/reference-sidebar.json`, both of which are
# generated artefacts — edit the Ruby comments in `lib/`, not the output.

require "tmpdir"
require_relative "rdoc_starlight"

DOCS_ROOT = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("..", DOCS_ROOT)

# Astro does not rewrite plain Markdown links with the site's `base`, so the
# links this generator emits have to carry it themselves. Read from the Astro
# config rather than repeated here, so the two cannot drift apart.
config = File.read(File.join(DOCS_ROOT, "astro.config.mjs"))
base = config[/^\s*base:\s*['"]([^'"]*)['"]/, 1]
raise "could not read `base` from astro.config.mjs" if base.nil?

ENV["STARLIGHT_BASE"] = base
ENV["STARLIGHT_CONTENT_DIR"] = File.join(DOCS_ROOT, "src", "content", "reference")
ENV["STARLIGHT_SIDEBAR_PATH"] = File.join(DOCS_ROOT, "src", "generated", "reference-sidebar.json")

Dir.chdir REPO_ROOT do
  RDoc::RDoc.new.document [
    "--format=starlight",
    "--quiet",
    # RDoc insists on an output directory even when the generator writes
    # elsewhere; nothing is created here.
    "--output=#{File.join(Dir.tmpdir, "rdoc-starlight-unused")}",
    "lib",
  ]
end
