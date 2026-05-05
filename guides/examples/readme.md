# Examples

Runnable examples demonstrating various Brute features.

## Available Examples

- `01_basic_agent.rb` -- Ask a question, get a response
- `02_fix_a_bug.rb` -- Agent reads a buggy file, patches it, runs tests to verify
- `03_session_persistence.rb` -- Two turns sharing the same session, demonstrating JSONL persistence
- `04_custom_rules.rb` -- Inject project-specific rules into the system prompt
- `05_multi_turn.rb` -- Three sequential turns with a shared session (the Getting Started example)
- `06_read_only_agent.rb` -- Restricted tool set, read-only code analysis
- `07_subagent_exploration.rb` -- Parallel sub-agent delegation with two concurrent explorers
- `08_a2a_server.rb` -- Expose a Brute agent as an HTTP service via the A2A protocol

## Running

Individual examples:

```bash
bundle exec ruby examples/01_basic_agent.rb
```

Run examples 01-06 sequentially:

```bash
./examples/run_all.sh
```

See the [examples/ directory](https://github.com/general-intelligence-systems/brute/tree/main/examples) for the full source code.
