---
name: notion
description: Search Notion and read/create/update pages and databases via Notion's official hosted MCP server. Tools are auto-discovered from the server at runtime.
---

# Notion

SCAFFOLD — no-op port of prime-agent `packages/coding-agent/skills/notion`.
The functions below exist but return a "not implemented" error payload; see
FEATURES.md (S13 + M13) for the fill-in contract.

Talk to Notion through its official hosted MCP server from the IRuby kernel.

## Setup

Connect via the host's login flow (upstream: `/login` -> Services -> Notion,
OAuth in the browser). Once connected, this skill is enabled automatically.
Until then every call reports not-enabled — walk the user through login;
don't ask them to set environment variables.

## Usage

The tool set is defined by the server, not by this skill, so **discover
before you call**. Notion's tools are named with hyphens (e.g.
`notion-search`, `notion-fetch`), which are not valid Ruby method names — so
call them via `call_tool`:

```ruby
require "notion"

Notion.list_tools.each { |tool| puts "#{tool["name"]} - #{tool["description"]}" }
Notion.call_tool("notion-search", query: "roadmap")
```
