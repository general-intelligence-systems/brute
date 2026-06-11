# code-reviewer

Senior code reviewer. Reviews PRs, identifies issues, suggests improvements with production standards.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/code-reviewer/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/code-reviewer/agent.toml).

The system prompt is verbatim; temperature (0.3) matches the manifest;
the manifest's tools (`file_read, file_list, shell_exec, memory_store, memory_recall`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/agents/openfang-based/code-reviewer/agent.rb "<your request>"
```
