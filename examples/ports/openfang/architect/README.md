# architect

System architect. Designs software architectures, evaluates trade-offs, creates technical specifications.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/architect/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/architect/agent.toml).

The system prompt is verbatim; temperature (0.3) matches the manifest;
the manifest's tools (`file_read, file_list, memory_store, memory_recall, agent_send`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/ports/openfang/architect/agent.rb "<your request>"
```
