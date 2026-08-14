# ruby-llm

Brute + ruby_llm (https://rubyllm.com) — Brute manages the turn.

## Run

```
nix run ./examples/ruby-llm
nix run ./examples ruby-llm        # via the dispatcher from the repo root
```

Defaults to a local Ollama (see docker-compose.yml at the repo root); override with BRUTE_PROVIDER / BRUTE_MODEL and the matching *_API_KEY.
