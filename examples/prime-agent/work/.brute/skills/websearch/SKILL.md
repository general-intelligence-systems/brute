---
name: websearch
description: Search Google via the Serper API. Takes one query and returns titles, URLs, snippets, and knowledge-graph data.
---

# Web Search

Search the web via the Serper Google Search API. Call directly from IRuby:

    require "websearch"
    Websearch.run("ruby zeromq kernel jupyter protocol")

## API

- `Websearch.run(query, max_output: 8192, timeout: 45, num_results: 5)` —
  formatted results: knowledge graph, organic results, people-also-ask;
  output truncated head+tail with a marker when over `max_output` chars.

## Notes

- API key: `SERPER_API_KEY` env, else `~/.prime/agent/auth.json` (`serper`
  api_key — the stored value may also be the NAME of an env var holding the
  key). Resolved on every call, so a key saved mid-session just works.
- Env knobs: `PRIME_AGENT_WEBSEARCH_TIMEOUT` (45),
  `PRIME_AGENT_WEBSEARCH_NUM_RESULTS` (5).
- When no key is configured, returns setup instructions instead of raising.
