# meeting-assistant

Meeting notes, action items, agenda preparation, and follow-up tracking agent.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/meeting-assistant/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/meeting-assistant/agent.toml).

The system prompt is verbatim; temperature (0.3) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/ports/openfang/meeting-assistant/agent.rb "<your request>"
```
