# llm-rb

Brute + llm.rb (https://github.com/llmrb/llm.rb) — Brute manages the turn.

## Run

```
nix run ./examples/llm-rb
nix run ./examples llm-rb        # via the dispatcher from the repo root
```

Defaults to a local Ollama (see docker-compose.yml at the repo root); override with BRUTE_PROVIDER / BRUTE_MODEL and the matching *_API_KEY.
