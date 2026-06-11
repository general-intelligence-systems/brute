# recruiter

Recruiting agent for resume screening, candidate outreach, job description writing, and hiring pipeline management.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/recruiter/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/recruiter/agent.toml).

The system prompt is verbatim; temperature (0.4) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, web_fetch`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/ports/openfang/recruiter/agent.rb "<your request>"
```
