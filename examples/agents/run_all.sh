#!/usr/bin/env bash
# Run all agent example scripts.
#
# They default to a local Ollama (see docker-compose.yml) — no API key needed.
# Start it first with `docker compose up -d`. Override the provider/model with
# BRUTE_PROVIDER / BRUTE_MODEL (see each example's header).

set -e
cd "$(dirname "$0")"

bundle exec ruby 01_basic_agent.rb
bundle exec ruby 01b_rubyllm_manages_tools.rb
bundle exec ruby 01c_brute_ru.rb
bundle exec ruby 02_fix_a_bug.rb
bundle exec ruby 03_session_persistence.rb
bundle exec ruby 04_custom_rules.rb
bundle exec ruby 05_multi_turn.rb
bundle exec ruby 06_read_only_agent.rb

# Example 07 spawns parallel sub-agents — slower (more model calls).
bundle exec ruby 07_subagent_exploration.rb

# Example 08 checkpoints every iteration; run twice to see resume.
rm -f tmp/checkpoints_08.jsonl
bundle exec ruby 08_checkpoints.rb
BRUTE_CHECKPOINT=latest bundle exec ruby 08_checkpoints.rb
