# assistant

General-purpose assistant agent. The default OpenClaw agent for everyday tasks, questions, and conversations.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/assistant/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/assistant/agent.toml).

The system prompt is verbatim; temperature (0.5) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, web_fetch, shell_exec, agent_send, agent_list`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/openfang-based/assistant/agent.rb "<your request>"
```
