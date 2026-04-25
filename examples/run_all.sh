#!/usr/bin/env bash
# Run all example scripts. All require an API key.

set -e
cd "$(dirname "$0")/.."

bundle exec ruby examples/01_basic_agent.rb
bundle exec ruby examples/02_fix_a_bug.rb
bundle exec ruby examples/03_session_persistence.rb
bundle exec ruby examples/04_custom_rules.rb
bundle exec ruby examples/05_multi_turn.rb
bundle exec ruby examples/06_read_only_agent.rb
