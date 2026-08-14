# orchestrator

Meta-agent that decomposes complex tasks, delegates to specialist agents, and synthesizes results.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/orchestrator/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/orchestrator/agent.toml).

The system prompt is verbatim; temperature (0.3) matches the manifest;
the manifest's tools (`agent_send, agent_spawn, agent_list, agent_kill, memory_store, memory_recall, file_read, file_write`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/ports/openfang/orchestrator/agent.rb "<your request>"
```
