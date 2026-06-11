# debugger

Expert debugger. Traces bugs, analyzes stack traces, performs root cause analysis.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/debugger/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/debugger/agent.toml).

The system prompt is verbatim; temperature (0.2) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, shell_exec, web_search, web_fetch, memory_store, memory_recall`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/openfang-based/debugger/agent.rb "<your request>"
```
