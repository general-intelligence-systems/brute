# Middleware

Brute uses a middleware pipeline to handle cross-cutting concerns like retries, token tracking, and session persistence.

## Building a Pipeline

```ruby
pipeline = Brute::Pipeline.new do
  use Brute::Middleware::Tracing,
    logger: Logger.new($stderr, level: Logger::INFO)
  use Brute::Middleware::Retry
  use Brute::Middleware::SessionPersistence, session: session
  use Brute::Middleware::TokenTracking
  use Brute::Middleware::ToolErrorTracking
  use Brute::Middleware::DoomLoopDetection
  use Brute::Middleware::ToolUseGuard
  run Brute::Middleware::LLMCall.new
end
```

## Built-in Middleware

| Middleware | Purpose |
|-----------|---------|
| `Tracing` | Logs agent activity |
| `Retry` | Retries failed LLM calls |
| `SessionPersistence` | Persists conversation history |
| `TokenTracking` | Tracks token usage |
| `ToolErrorTracking` | Tracks tool execution errors |
| `DoomLoopDetection` | Detects and breaks infinite loops |
| `ToolUseGuard` | Guards against unauthorized tool use |
| `LLMCall` | The terminal middleware that calls the LLM |
