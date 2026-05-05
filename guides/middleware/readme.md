# Middleware

Brute uses a middleware pipeline (Rack-style) to handle cross-cutting concerns. `Brute::Agent` inherits from `Brute::Pipeline`, so you configure the stack directly in the agent's block.

## Building an Agent Pipeline

```ruby
agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL,
) do
  use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end
```

Middleware is executed top-to-bottom on the way in, and bottom-to-top on the way out. The `run` call defines the terminal middleware (always `LLMCall`).

## Built-in Middleware

| Middleware | Purpose |
|-----------|---------|
| `EventHandler` | Emits events to a handler (e.g. terminal output) |
| `SystemPrompt` | Prepends the system prompt to the message list |
| `ToolResultLoop` | Re-invokes the stack when the last message is a tool result |
| `MaxIterations` | Caps iteration count (default 100) to prevent runaway loops |
| `ToolCall` | Dispatches tool calls from the LLM response to tool implementations |
| `Summarize` | Summarizes sub-agent results for the parent agent |
| `CompactionCheck` | Compacts long sessions to stay within context limits |
| `Tracing` | Logs timing and token usage per LLM call |
| `Question` | Handles interactive user questions from the agent |
| `OtelSpan` | OpenTelemetry span instrumentation |
| `LLMCall` | Terminal middleware -- sends messages to the LLM provider |

## Middleware Options

Some middleware accepts configuration:

```ruby
# Tracing with a custom logger
use Brute::Middleware::Tracing, logger: Logger.new($stderr, level: Logger::INFO)

# MaxIterations with a custom cap
use Brute::Middleware::MaxIterations, max_iterations: 15

# SystemPrompt with a custom prompt builder
use Brute::Middleware::SystemPrompt, system_prompt: my_custom_prompt

# EventHandler with a prefixed output (useful for sub-agents)
use Brute::Middleware::EventHandler,
    handler_class: Brute::Events::PrefixedTerminalOutput,
    prefix: "arch"
```

## Execution Model

When `agent.call(session)` is invoked:

1. The session messages are passed through the middleware stack.
2. `SystemPrompt` prepends the system message.
3. `LLMCall` sends the messages to the LLM and appends the response.
4. `ToolCall` dispatches any tool calls in the response (concurrently via `Async::Barrier`).
5. `ToolResultLoop` detects that the last message is a tool result and re-invokes the stack.
6. This loop continues until the LLM responds without tool calls, or `MaxIterations` halts it.
