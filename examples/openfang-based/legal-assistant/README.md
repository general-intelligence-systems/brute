# legal-assistant

Legal assistant agent for contract review, legal research, compliance checking, and document drafting.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/legal-assistant/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/legal-assistant/agent.toml).

The system prompt is verbatim; temperature (0.2) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, web_fetch`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/openfang-based/legal-assistant/agent.rb "<your request>"
```
