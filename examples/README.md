# Examples

Every example is its own runnable agent directory — a mirror of
~/src/agents. Each directory is a self-contained nix subflake (`flake.nix`,
`Gemfile` + `Gemfile.lock` + `gemset.nix`, `main.rb`, `work/`), runnable with
`nix run` from the repo root:

```
nix run ./examples/01-basic-agent          # direct
nix run ./examples 01-basic-agent          # via the dispatcher flake in this dir
nix run ./examples/<name>#schedule <dir>   # systemd timer (see each README)
```

The runner copies the agent's `work/*` into your current directory, then runs
its `main.rb` with your cwd as the working directory.

## Agents

Walkthrough series (numbered, in increasing complexity):

| Agent | Shows |
|-------|-------|
| [01-basic-agent](01-basic-agent/) | the canonical middleware stack; Brute manages the turn |
| [01b-rubyllm-manages-tools](01b-rubyllm-manages-tools/) | RubyLLM owns the tool loop instead ⚠️ 2.x API |
| [01c-brute-ru](01c-brute-ru/) | agent described in a `brute.ru` rackup-style file (+ `config.ru` to serve over HTTP) |
| [02-fix-a-bug](02-fix-a-bug/) | agent patches a buggy file and verifies ⚠️ 2.x API |
| [03-session-persistence](03-session-persistence/) | JSONL session resume across runs ⚠️ 2.x API |
| [04-custom-rules](04-custom-rules/) | behavior constraints via system prompt ⚠️ 2.x API |
| [05-multi-turn](05-multi-turn/) | three turns over a shared session ⚠️ 2.x API |
| [06-read-only-agent](06-read-only-agent/) | restricted tool set ⚠️ 2.x API |
| [07-subagent-exploration](07-subagent-exploration/) | parallel read-only sub-agents ⚠️ 2.x API |
| [08-checkpoints](08-checkpoints/) | durable tool-loop checkpoints, resume & fork |

⚠️ 2.x API = written against `Brute::Agent.new` / `Brute::Session` / `LLMCall`
(removed in brute 3.0); kept as walkthrough reference, pending 3.x rewrites.

One directory per LLM library — the same agent, different terminal `run` proc:

| Agent | Library |
|-------|---------|
| [ruby-llm](ruby-llm/) | [ruby_llm](https://rubyllm.com) |
| [llm-rb](llm-rb/) | [llm.rb](https://github.com/llmrb/llm.rb) |
| [openai](openai/) | [openai](https://github.com/openai/openai-ruby) |
| [anthropic](anthropic/) | [anthropic](https://github.com/anthropics/anthropic-sdk-ruby) |
| [open-router](open-router/) | [open_router_enhanced](https://github.com/estiens/open_router_enhanced) |

Ports of other projects' agents (prompts verbatim, feature checklist in code):

| Agent | Source |
|-------|--------|
| [prime-agent](prime-agent/) | [PrimeIntellect-ai/prime-agent](https://github.com/PrimeIntellect-ai/prime-agent) |

Most default to a local Ollama (see `docker-compose.yml` at the repo root) —
no API key needed. Override with `BRUTE_PROVIDER` / `BRUTE_MODEL`.

## Other directories

- **[ports](ports/)** — ported agents/teams as plain Ruby (not nix subflakes
  yet): dexter, openfang, browser-agent, google-calendar-agent, grafana-agent,
  paperclip. Prompts verbatim from their sources; each README links the
  original.
- **[teams](teams/)**, **[workflows](workflows/)** — nothing here yet.

## Adding a new agent

```
cp -r examples/prime-agent examples/<name>
# edit main.rb + Gemfile, then regenerate the gem set:
cd examples/<name> && nix shell nixpkgs#bundix -c bundix -l
```
