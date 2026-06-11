# devops-lead

DevOps lead. Manages CI/CD, infrastructure, deployments, monitoring, and incident response.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/devops-lead/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/devops-lead/agent.toml).

The system prompt is verbatim; temperature (0.2) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, shell_exec, memory_store, memory_recall, agent_send`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/agents/openfang-based/devops-lead/agent.rb "<your request>"
```
