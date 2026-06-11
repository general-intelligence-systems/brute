# translator

Multi-language translation agent for document translation, localization, and cross-cultural communication.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/translator/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/translator/agent.toml).

The system prompt is verbatim; temperature (0.3) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, web_fetch`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/ports/openfang/translator/agent.rb "<your request>"
```
