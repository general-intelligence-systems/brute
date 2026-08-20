# brute

> ⚠️ **Upgrading to v3?** Brute 3.0.1 removes the hard dependency on `ruby_llm`
> and replaces the old `Brute.rubyllm_tools` helper with a library-agnostic
> `Brute.tools` + `Brute::MessageTransport` API. **This is a breaking change
> relative to the 3.0.0 gem** — the 3.0.0 release accidentally shipped without
> the transport refactor. See [CHANGELOG.md](./CHANGELOG.md) for the migration
> steps and pick a transport under `Brute::MessageTransport::*` that matches
> your LLM library.

A framework-agnostic coding agent for Ruby. Rack-style middleware pipelines for
agent turns, a full set of coding tools, and session persistence — bring your
own LLM library.

Brute treats an agent turn the way Rack treats an HTTP request: an `env` hash
flowing through a middleware stack toward a terminal app. The middleware handles
the agentic machinery — the tool loop, session persistence, the system prompt,
iteration guards. The terminal app is a proc **you** write with whatever LLM
library you prefer ([ruby_llm](https://rubyllm.com),
[llm.rb](https://github.com/llmrb/llm.rb), the official
[openai](https://github.com/openai/openai-ruby) or
[anthropic](https://github.com/anthropics/anthropic-sdk-ruby) gems, or raw
HTTP). Brute depends on none of them.

## Usage

See the [project documentation](https://general-intelligence-systems.github.io/brute/):

- [Getting Started](https://general-intelligence-systems.github.io/brute/getting-started/) — install brute and build your first agent.
- [The Agent Pipeline](https://general-intelligence-systems.github.io/brute/agents/) — `Brute.agent`, `.use`, `.run`, `.start`.
- [Messages](https://general-intelligence-systems.github.io/brute/messages/) — the `Brute::Message` format.
- [Message Transports](https://general-intelligence-systems.github.io/brute/message-transports/) — translate between Brute and any LLM library.
- [Tools](https://general-intelligence-systems.github.io/brute/tools/) — four ways to define a tool; the built-in coding toolset.
- [Middleware](https://general-intelligence-systems.github.io/brute/middleware/) — the built-in turn middleware catalog.

## Quick start

```ruby
require "brute"
require "ruby_llm"

agent = Brute.agent
  .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
  .run do |env|
    response = provider.complete(
      Brute::MessageTransport::RubyLLM.dump_all(env[:messages]),
      tools: rubyllm_tools(env[:tools]), model: model,
    )
    Brute::MessageTransport::RubyLLM.wrap_each(response) { |m| env[:messages] << m }
  end

agent.start("What files are in the current directory?")
```

## Docs

The documentation site is a [Just the Docs](https://just-the-docs.com/) Jekyll
project under `docs/`. Serve it locally:

```sh
docs/bin/serve.sh          # http://localhost:4000/brute/
```

## Contributing

- [DEPRECATIONS.md](DEPRECATIONS.md) — how public names are deprecated and
  removed. Read this before renaming or deleting anything public.
- [RELEASE.md](RELEASE.md) — the release process and the versioning rules.
- [CHANGELOG.md](CHANGELOG.md) — what changed in each version.

## See Also

- [Examples directory](https://github.com/general-intelligence-systems/brute/tree/main/examples) — the same agent on four LLM libraries, plus sub-agents, sessions, and HTTP serving.

## License

MIT
