# 01c-brute-ru

Basic agent — loaded from a brute.ru file.

## Run

```
nix run ./examples/01c-brute-ru
nix run ./examples 01c-brute-ru        # via the dispatcher from the repo root
```

Ollama defaults to localhost:11434 (see docker-compose.yml at the repo root); override with BRUTE_PROVIDER / BRUTE_MODEL and the matching *_API_KEY.
