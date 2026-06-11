# ops

DevOps agent. Monitors systems, runs diagnostics, manages deployments.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/ops/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/ops/agent.toml).

The system prompt is verbatim; temperature (0.2) matches the manifest;
the manifest's tools (`shell_exec, file_read, file_list`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/openfang-based/ops/agent.rb "<your request>"
```
