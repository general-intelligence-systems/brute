# tutor

Teaching and explanation agent for learning, tutoring, and educational content creation.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/tutor/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/tutor/agent.toml).

The system prompt is verbatim; temperature (0.5) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, shell_exec, web_fetch`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/agents/openfang-based/tutor/agent.rb "<your request>"
```
