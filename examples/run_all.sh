#!/bin/bash
# Run all example scripts. All require an API key.

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
  local name=$(basename "$file" .rb)

  if [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$OPENAI_API_KEY" ] && [ -z "$GOOGLE_API_KEY" ] && [ -z "$LLM_API_KEY" ]; then
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
    bundle exec ruby "$file" 2>&1 | tail -5 | sed 's/^/     /'
  fi
}

echo "=== Brute Examples ==="
echo

run_example examples/01_basic_agent.rb
run_example examples/02_fix_a_bug.rb
run_example examples/03_session_persistence.rb
run_example examples/04_custom_rules.rb
run_example examples/05_multi_turn.rb
run_example examples/06_read_only_agent.rb
run_example examples/07_agent_turn.rb

echo
echo "=== $pass passed, $fail failed, $skip skipped ==="

[ $fail -eq 0 ] || exit 1
