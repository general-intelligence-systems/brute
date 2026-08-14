---
layout: default
title: Examples
nav_order: 1
description: 'Runnable agents in the repo — the same coding agent on four LLM libraries, plus session persistence, sub-agents, and HTTP serving.'
---

# Examples

Every example is its own runnable agent directory under `examples/` — a self-contained nix subflake (`flake.nix`, `Gemfile` + `gemset.nix`, `main.rb`, `work/`). Run one from the repo root with `nix run ./examples/<name>` (or `nix run ./examples <name>` via the dispatcher). They default to a local [Ollama](https://ollama.com) (`llama3.2`); set `BRUTE_PROVIDER`, `BRUTE_MODEL`, and an API key to run against a hosted model. You can also run a `main.rb` directly with `ruby` inside `nix develop ./examples/<name>`.

## The same agent, four libraries

These four build the *identical* agent — same middleware stack, same tools, same task. Only the terminal `run` proc differs, showing the [MessageTransport]({% link _core_features/message-transports.md %}) for each library:

| Directory | Library | Run it |
|---|---|---|
| `examples/ruby-llm/` | [ruby_llm](https://rubyllm.com) | `nix run ./examples/ruby-llm` |
| `examples/llm-rb/` | [llm.rb](https://github.com/llmrb/llm.rb) | `nix run ./examples/llm-rb` |
| `examples/openai/` | [openai](https://github.com/openai/openai-ruby) | `OPENAI_API_KEY=... nix run ./examples/openai` |
| `examples/anthropic/` | [anthropic](https://github.com/anthropics/anthropic-sdk-ruby) | `ANTHROPIC_API_KEY=... nix run ./examples/anthropic` |

Read their `main.rb` files side by side to see exactly what changes when you swap LLM libraries — and what doesn't (the whole middleware stack).

## Tool advertising

Each example includes a small helper that turns Brute's neutral tool adapters into its library's tool format via `Brute.tools(env[:tools])` and `adapter.to_h`. For example, the OpenAI one:

```ruby
def openai_tools(tools)
  Brute.tools(tools).values.map do |adapter|
    d = adapter.to_h
    { type: "function", function: { name: d[:name], description: d[:description], parameters: d[:parameters] } }
  end
end
```

The ruby_llm version builds `RubyLLM::Tool` classes; the anthropic version emits `{ name:, description:, input_schema: }`. Same source adapter, different shape — see [Tools]({% link _core_features/tools.md %}).

## More agents

Numbered walkthroughs, one directory each:

| Directory | Shows |
|---|---|
| `01-basic-agent/` | the canonical inline agent (ruby_llm) |
| `01c-brute-ru/` + `brute.ru` | an agent defined in rackup syntax, loaded with `parse_file` |
| `01c-brute-ru/config.ru` | serving that agent over HTTP via [`Brute::Rack::Adapter`]({% link _advanced/rack.md %}) |
| `03-session-persistence/` | [`SessionLog`]({% link _advanced/sessions.md %}) across turns |
| `05-multi-turn/` | a continuing conversation |
| `06-read-only-agent/` | a restricted tool set |
| `07-subagent-exploration/` | [sub-agents]({% link _advanced/sub-agents.md %}) delegating work |
| `08-checkpoints/` | durable tool-loop checkpoints, resume & fork |

Plus ported agents as their own directories — see `examples/prime-agent/` — and plain-Ruby ports under `examples/ports/`.

## Serving over HTTP

```sh
rackup examples/01c-brute-ru/config.ru      # or: falcon serve -c examples/01c-brute-ru/config.ru

curl -d 'What files are here? List them.' localhost:9292
curl -H 'content-type: application/json' -d '{"prompt":"hi"}' localhost:9292
```

See [Serving over HTTP]({% link _advanced/rack.md %}) for the request/response details.
