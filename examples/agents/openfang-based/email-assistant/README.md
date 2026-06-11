# email-assistant

Email triage, drafting, scheduling, and inbox management agent.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/email-assistant/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/email-assistant/agent.toml).

The system prompt is verbatim; temperature (0.4) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, web_fetch`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/agents/openfang-based/email-assistant/agent.rb "<your request>"
```
