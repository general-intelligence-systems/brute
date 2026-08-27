# Brute


A framework-agnostic coding agent for Ruby. Rack-style middleware pipelines for
agent turns, a full set of coding tools, and session persistence — bring your
own LLM library.

Brute treats an agent turn the way [Rack](https://rack.github.io/) treats an
HTTP request: an `env` hash flowing through a middleware stack toward a terminal
app. The middleware handles the agentic machinery — the tool loop, session
persistence, the system prompt, iteration guards. The terminal app is a proc
**you** write with whatever LLM library you prefer ([ruby_llm](https://rubyllm.com),
[llm.rb](https://github.com/llmrb/llm.rb), the official
[openai](https://github.com/openai/openai-ruby) or
[anthropic](https://github.com/anthropics/anthropic-sdk-ruby) gems, or raw
HTTP). Brute depends on none of them.

> ⚠️ **Upgrading to v3?** Brute 3.0.1 removes the hard dependency on `ruby_llm`
> and replaces the old `Brute.rubyllm_tools` helper with a library-agnostic
> `Brute.tools` + `Brute::MessageTransport` API. **This is a breaking change
> relative to the 3.0.0 gem** — the 3.0.0 release accidentally shipped without
> the transport refactor. See [CHANGELOG.md](CHANGELOG.md) for the migration
> steps and pick a transport under `Brute::MessageTransport::*` that matches
> your LLM library.

## Features

- **Rack-style agent turns** — compose middleware around your LLM call; the
  agentic loop is just another layer.
- **Bring your own LLM** — no completion middleware and no LLM dependency;
  `MessageTransport` classes translate at the boundary for ruby_llm, llm.rb,
  openai, and anthropic.
- **A full coding toolset** — read/write/patch/remove/search files, shell,
  HTTP fetch, todo lists, interactive questions, skills, sub-agents — executed
  concurrently with universal output truncation.
- **Session persistence** — the conversation log is JSONL on disk; reload it,
  fork it, or checkpoint and resume a crashed turn.
- **Context management** — sliding-window and tool-result compaction strategies
  with an optional summarizer, once the conversation fills the model's window.
- **Skills** — markdown instruction files implementing the
  [Agent Skills specification](https://agentskills.io/specification), surfaced
  with progressive disclosure.
- **Evals** — grade whole assembled agents on what their turns *did*, with
  stubbed tools and budgets.
- **Serve anywhere** — wrap any agent as a Rack app behind Falcon or Puma.

## Requirements

- Ruby >= 3.3
- An LLM library of your choice (optional — only your `run` proc needs one)

## Installation

Add Brute — plus whichever LLM library you plan to call — to your Gemfile:

```ruby
gem "brute"

# plus one of:
gem "ruby_llm"
# gem "llm.rb"
# gem "openai"
# gem "anthropic"
```

Then execute:

```sh
bundle install
```

## Usage

Build an agent by chaining middleware and finishing with your LLM call:

```ruby
require "brute"
require "ruby_llm"

agent = Brute.agent
  .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::DefaultToolPipeline, tools: Brute::Tools::ALL)
  .run do |env|
    response = provider.complete(
      Brute::MessageTransport::RubyLLM.dump_all(env[:messages]),
      tools: rubyllm_tools(env[:tools]), model: model,
    )
    Brute::MessageTransport::RubyLLM.wrap_each(response) { |m| env[:messages] << m }
  end

agent.start("What files are in the current directory? List them.")
```

Everything about the LLM — provider, model, credentials — lives inside the
`run` proc. Swap the proc and the same stack runs on any library; the
[examples directory](https://github.com/general-intelligence-systems/brute/tree/main/examples)
ships this exact agent four times over, runnable with `nix run ./examples/ruby-llm`.

## Documentation

Full documentation lives at
[general-intelligence-systems.github.io/brute](https://general-intelligence-systems.github.io/brute/),
organized as [tutorials](https://general-intelligence-systems.github.io/brute/getting-started/),
[how-to guides](https://general-intelligence-systems.github.io/brute/sub-agents/),
and [concepts](https://general-intelligence-systems.github.io/brute/rack-model/),
plus an auto-generated API reference. To work on the docs locally:

```sh
docs/bin/serve.sh          # http://localhost:4000/brute/
```

## Support

Please [open an issue](https://github.com/general-intelligence-systems/brute/issues)
for bugs, questions, and feature requests.

## Roadmap

Deprecated public names (see `gem kit deprecations` and
[DEPRECATIONS.md](DEPRECATIONS.md)) are removed in major versions only. Notable
changes land in [CHANGELOG.md](CHANGELOG.md), which follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Contributing

Contributions are welcome. Pull requests should come with tests.

```sh
nix develop        # or: bundle install
bin/test           # the full suite (scampi TAP output)
```

Before renaming or deleting anything public, read
[DEPRECATIONS.md](DEPRECATIONS.md) — public names are deprecated with
`GemKit::Deprecate`, never deleted outright. The release process and versioning
rules are in [RELEASE.md](RELEASE.md).

## License

[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0)
