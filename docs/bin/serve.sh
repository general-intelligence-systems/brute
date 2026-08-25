#!/usr/bin/env bash
# Serve the docs locally with live reload.
#   docs/bin/serve.sh   |   PORT=4002 docs/bin/serve.sh
#
# The site is Astro/Starlight. `nix develop` provides node; otherwise any
# Node 20+ on PATH will do.
set -euo pipefail

# Drop any parent bundle's env — this is a Node project, not a Ruby one.
unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_BIN BUNDLE_APP_CONFIG 2>/dev/null || true

PORT="${PORT:-4000}"
docs="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$docs"

if ! command -v npm >/dev/null 2>&1; then
  echo "npm not found — run 'nix develop' first, or install Node 20+." >&2
  exit 1
fi

# package-lock.json is committed, so `npm ci` gives the exact pinned tree.
if [ ! -d node_modules ]; then
  echo "==> Installing docs dependencies"
  npm ci
fi

echo "==> Serving http://localhost:$PORT/brute/ — Ctrl-C to stop"
exec npm run dev -- --port "$PORT"
