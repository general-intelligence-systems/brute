# Providers

Brute supports multiple LLM providers with automatic detection from environment variables.

## Supported Providers

| Name | Auto-detect env var |
|------|-------------------|
| `anthropic` | `ANTHROPIC_API_KEY` |
| `openai` | `OPENAI_API_KEY` |
| `google` | `GOOGLE_API_KEY` |
| `deepseek` | `LLM_API_KEY` + `LLM_PROVIDER=deepseek` |
| `ollama` | `OLLAMA_HOST` (no key needed) |
| `xai` | `LLM_API_KEY` + `LLM_PROVIDER=xai` |

## Auto-Detection

Brute checks environment variables in order and uses the first match:

```ruby
provider = Brute::Providers.guess_from_env
```

## Explicit Configuration

Set the provider and key explicitly:

```sh
export LLM_API_KEY=your-key
export LLM_PROVIDER=anthropic  # openai | google | deepseek | ollama | xai
```
