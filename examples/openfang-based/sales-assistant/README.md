# sales-assistant

Sales assistant agent for CRM updates, outreach drafting, pipeline management, and deal tracking.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/sales-assistant/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/sales-assistant/agent.toml).

The system prompt is verbatim; temperature (0.5) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, web_fetch`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/openfang-based/sales-assistant/agent.rb "<your request>"
```
