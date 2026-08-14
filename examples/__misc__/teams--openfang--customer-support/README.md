# customer-support

Customer support agent for ticket handling, issue resolution, and customer communication.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/customer-support/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/customer-support/agent.toml).

The system prompt is verbatim; temperature (0.3) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, web_fetch`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/ports/openfang/customer-support/agent.rb "<your request>"
```
