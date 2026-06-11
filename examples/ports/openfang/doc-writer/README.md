# doc-writer

Technical writer. Creates documentation, README files, API docs, tutorials, and architecture guides.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/doc-writer/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/doc-writer/agent.toml).

The system prompt is verbatim; temperature (0.4) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/ports/openfang/doc-writer/agent.rb "<your request>"
```
