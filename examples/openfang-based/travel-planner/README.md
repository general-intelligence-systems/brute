# travel-planner

Trip planning agent for itinerary creation, booking research, budget estimation, and travel logistics.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source manifest: [`agents/travel-planner/agent.toml`](https://github.com/RightNow-AI/openfang/blob/main/agents/travel-planner/agent.toml).

The system prompt is verbatim; temperature (0.5) matches the manifest;
the manifest's tools (`file_read, file_write, file_list, memory_store, memory_recall, web_search, web_fetch, browser_navigate, browser_click, browser_type, browser_read_page, browser_screenshot, browser_close`) are mapped to brute tools via
[`../tools.rb`](../tools.rb).

## Usage

```sh
export ANTHROPIC_API_KEY=...
bundle exec ruby examples/openfang-based/travel-planner/agent.rb "<your request>"
```
