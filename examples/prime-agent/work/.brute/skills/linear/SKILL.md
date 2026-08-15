---
name: linear
description: Read and write Linear issues, projects, cycles, comments, and more via Linear's official MCP server. Tools are auto-discovered from the server at runtime.
---

# Linear

SCAFFOLD — no-op port of prime-agent `packages/coding-agent/skills/linear`.
The functions below exist but return a "not implemented" error payload; see
FEATURES.md (S12 + M13) for the fill-in contract.

Talk to Linear through its official hosted MCP server from the IRuby kernel.

## Setup

Connect via the host's login flow (upstream: `/login` -> Services -> Linear,
OAuth in the browser). Once connected, this skill is enabled automatically.
Until then every call reports not-enabled — walk the user through login;
don't ask them to set environment variables.

## Usage

The tool set is defined by the server, not by this skill, so **discover
before you call** — don't assume tool names or argument names:

```ruby
require "linear"

# 1. Discover available tools
Linear.list_tools.each { |tool| puts "#{tool["name"]} - #{tool["description"]}" }

# 2. Call one
Linear.call_tool("list_issues", team: "Engineering")
```
