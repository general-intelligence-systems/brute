# hello-world

A friendly greeting agent that can read files, search the web, and answer everyday questions.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/hello-world/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/hello-world/agent.toml).

The system prompt is verbatim; temperature (0.6) matches the manifest;
the manifest's tools (`file_read, file_list, web_fetch, web_search, memory_store, memory_recall`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/ports/openfang/hello-world/agent.rb "<your request>"
```
