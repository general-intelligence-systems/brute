# 01-basic-agent

Basic agent — Brute manages the turn.

## Run

```
nix run ./examples/01-basic-agent
nix run ./examples 01-basic-agent        # via the dispatcher from the repo root
```

Ollama defaults to localhost:11434 (see docker-compose.yml at the repo root); override with BRUTE_PROVIDER / BRUTE_MODEL and the matching *_API_KEY.
