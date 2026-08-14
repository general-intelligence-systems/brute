# 07-subagent-exploration

Parallel sub-agent exploration — a parent agent spawns two read-only.\n\n> ⚠️ Written against the brute 2.x API (`Brute::Agent.new` / `Brute::Session` / `LLMCall`) — pending a 3.x rewrite.

## Run

```
nix run ./examples/07-subagent-exploration
nix run ./examples 07-subagent-exploration        # via the dispatcher from the repo root
```

Ollama defaults to localhost:11434 (see docker-compose.yml at the repo root); override with BRUTE_PROVIDER / BRUTE_MODEL and the matching *_API_KEY.
