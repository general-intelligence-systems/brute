# Providers

Brute supports multiple LLM providers via [RubyLLM](https://rubyllm.com). Provider detection is handled by RubyLLM based on environment variables.

## Supported Providers

| Name | Auto-detect env var |
|------|-------------------|
| `anthropic` | `ANTHROPIC_API_KEY` |
| `openai` | `OPENAI_API_KEY` |
| `google` | `GOOGLE_API_KEY` |
| `deepseek` | `LLM_API_KEY` + `LLM_PROVIDER=deepseek` |
| `ollama` | `OLLAMA_HOST` (no key needed) |
| `xai` | `LLM_API_KEY` + `LLM_PROVIDER=xai` |

## Configuration

Brute exposes a global provider accessor that defaults to `:anthropic`:

```ruby
Brute.provider          # => :anthropic (default)
Brute.provider = :openai  # switch to OpenAI
```

Set the provider and key via environment variables:

```bash
export ANTHROPIC_API_KEY=sk-...
```

Or for providers that aren't auto-detected by key name:

```bash
export LLM_API_KEY=your-key
export LLM_PROVIDER=deepseek  # openai | google | deepseek | ollama | xai
```

## Usage in Agents

Pass the provider when creating an agent:

```ruby
agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL,
) do
  # middleware stack...
end
```
