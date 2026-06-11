# health-tracker

Wellness tracking agent for health metrics, medication reminders, fitness goals, and lifestyle habits.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/health-tracker/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/health-tracker/agent.toml).

The system prompt is verbatim; temperature (0.3) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/agents/openfang-based/health-tracker/agent.rb "<your request>"
```
