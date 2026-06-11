# personal-finance

Personal finance agent for budget tracking, expense analysis, savings goals, and financial planning.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/personal-finance/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/personal-finance/agent.toml).

The system prompt is verbatim; temperature (0.2) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, shell_exec`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/openfang-based/personal-finance/agent.rb "<your request>"
```
