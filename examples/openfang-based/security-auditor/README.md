# security-auditor

Security specialist. Reviews code for vulnerabilities, checks configurations, performs threat modeling.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/security-auditor/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/security-auditor/agent.toml).

The system prompt is verbatim; temperature (0.2) matches the manifest;
the manifest's tools (`file_read, file_list, shell_exec, memory_store, memory_recall`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/openfang-based/security-auditor/agent.rb "<your request>"
```
