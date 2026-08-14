# planner

Project planner. Creates project plans, breaks down epics, estimates effort, identifies risks and dependencies.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/planner/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/planner/agent.toml).

The system prompt is verbatim; temperature (0.3) matches the manifest;
the manifest's tools (`file_read, file_list, memory_store, memory_recall, agent_send`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/ports/openfang/planner/agent.rb "<your request>"
```
