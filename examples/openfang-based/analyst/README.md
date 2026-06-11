# analyst

Data analyst. Processes data, generates insights, creates reports.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/analyst/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/analyst/agent.toml).

The system prompt is verbatim; temperature (0.4) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, shell_exec, web_search, web_fetch, memory_store, memory_recall`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/openfang-based/analyst/agent.rb "<your request>"
```
