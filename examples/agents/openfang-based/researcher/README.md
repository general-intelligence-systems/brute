# researcher

Research agent. Fetches web content and synthesizes information.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/researcher/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/researcher/agent.toml).

The system prompt is verbatim; temperature (0.5) matches the manifest;
the manifest's tools (`web_search, web_fetch, file_read, file_write, file_list, memory_store, memory_recall`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/agents/openfang-based/researcher/agent.rb "<your request>"
```
