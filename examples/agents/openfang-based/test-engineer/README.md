# test-engineer

Quality assurance engineer. Designs test strategies, writes tests, validates correctness.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/test-engineer/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/test-engineer/agent.toml).

The system prompt is verbatim; temperature (0.3) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, shell_exec, memory_store, memory_recall`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/agents/openfang-based/test-engineer/agent.rb "<your request>"
```
