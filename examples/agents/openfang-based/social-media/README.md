# social-media

Social media content creation, scheduling, and engagement strategy agent.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/social-media/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/social-media/agent.toml).

The system prompt is verbatim; temperature (0.7) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, web_fetch`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/agents/openfang-based/social-media/agent.rb "<your request>"
```
