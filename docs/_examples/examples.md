---
layout: default
title: Examples
nav_order: 1
description: 'Runnable agents in the repo — the same coding agent on four LLM libraries, plus session persistence, sub-agents, and HTTP serving.'
---

# Examples

Every example is a runnable script in the repo's `examples/` directory. They default to a local [Ollama](https://ollama.com) (`llama3.2`); set `BRUTE_PROVIDER`, `BRUTE_MODEL`, and an API key to run against a hosted model.

## The same agent, four libraries

These four scripts build the *identical* agent — same middleware stack, same tools, same task. Only the terminal `run` proc differs, showing the [MessageTransport]({% link _core_features/message-transports.md %}) for each library:

| Script | Library | Run it |
|---|---|---|
| `examples/ruby_llm.rb` | [ruby_llm](https://rubyllm.com) | `ruby examples/ruby_llm.rb` |
| `examples/llm.rb` | [llm.rb](https://github.com/llmrb/llm.rb) | `ruby examples/llm.rb` |
| `examples/openai.rb` | [openai](https://github.com/openai/openai-ruby) | `OPENAI_API_KEY=... ruby examples/openai.rb` |
| `examples/anthropic.rb` | [anthropic](https://github.com/anthropics/anthropic-sdk-ruby) | `ANTHROPIC_API_KEY=... ruby examples/anthropic.rb` |

Read them side by side to see exactly what changes when you swap LLM libraries — and what doesn't (the whole middleware stack).

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

Under `examples/agents/`:

| Script | Shows |
|---|---|
| `01_basic_agent.rb` | the canonical inline agent (ruby_llm) |
| `01c_brute_ru.rb` + `brute.ru` | an agent defined in rackup syntax, loaded with `parse_file` |
| `config.ru` | serving that agent over HTTP via [`Brute::Rack::Adapter`]({% link _advanced/rack.md %}) |
| `03_session_persistence.rb` | [`SessionLog`]({% link _advanced/sessions.md %}) across turns |
| `05_multi_turn.rb` | a continuing conversation |
| `06_read_only_agent.rb` | a restricted tool set |
| `07_subagent_exploration.rb` | [sub-agents]({% link _advanced/sub-agents.md %}) delegating work |

## Serving over HTTP

```sh
rackup examples/agents/config.ru      # or: falcon serve -c examples/agents/config.ru

curl -d 'What files are here? List them.' localhost:9292
curl -H 'content-type: application/json' -d '{"prompt":"hi"}' localhost:9292
```

See [Serving over HTTP]({% link _advanced/rack.md %}) for the request/response details.
