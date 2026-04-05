#!/bin/bash
# Run all example scripts.
# Scripts 01-07 need no API key.
# Scripts 08-09 require ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY.
# Flow examples live in brute_flow/examples.

set -e
cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass=0
fail=0
skip=0

run_example() {
  local file="$1"
  local needs_key="${2:-false}"
  local name=$(basename "$file" .rb)

  if [ "$needs_key" = "true" ] && [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$OPENAI_API_KEY" ] && [ -z "$GOOGLE_API_KEY" ]; then
    printf "${YELLOW}SKIP${NC} %s (no API key)\n" "$name"
    skip=$((skip + 1))
    return
  fi

  printf "RUN  %s... " "$name"
  if bundle exec ruby "$file" > /dev/null 2>&1; then
    printf "${GREEN}PASS${NC}\n"
    pass=$((pass + 1))
  else
    printf "${RED}FAIL${NC}\n"
    fail=$((fail + 1))
    # Re-run to show output
    bundle exec ruby "$file" 2>&1 | tail -5 | sed 's/^/     /'
  fi
}

echo "=== Brute Examples ==="
echo

run_example examples/01_tools.rb
run_example examples/02_snapshot_undo.rb
run_example examples/03_doom_loop.rb
run_example examples/04_hooks.rb
run_example examples/05_session.rb
run_example examples/06_system_prompt.rb
run_example examples/07_pipeline.rb
run_example examples/08_agent_simple.rb true
run_example examples/09_agent_multi_tool.rb true

echo
echo "=== $pass passed, $fail failed, $skip skipped ==="

[ $fail -eq 0 ] || exit 1
