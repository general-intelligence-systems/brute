# prime-agent

[PrimeIntellect-ai/prime-agent](https://github.com/PrimeIntellect-ai/prime-agent)
ported to brute. `main.rb` carries a faithful port of prime-agent's system
prompt (`core/system-prompt.ts` + `core/prompts/rlm.ts`); the prompt blocks
whose features don't exist in brute yet (IPython kernel, `rlm` recursion,
continual harness) are ported verbatim as constants, unwired, as the porting
checklist.

Requires `OPENROUTER_API_KEY` (override the model with `BRUTE_MODEL`).

## Run once

Copies `work/*` into the current directory (a starter `.brute/skills/`) and
runs `main.rb` with the current directory as working directory:

```
nix run ./examples/prime-agent                       # from the brute repo root
nix run ./examples/prime-agent -- --overwrite        # replace existing work/* copies
nix run ./examples prime-agent                       # via the examples dispatcher
nix run ./examples/prime-agent -- "fix the failing test"   # custom task
```

## Scheduled operation

Install (or update — re-running is idempotent) a systemd timer that runs the
agent as a dynamic user, sandboxed, with only `<dir>` writable:

```
nix run ./examples/prime-agent#schedule <dir>
```

Cadence via `PRIME_AGENT_SCHEDULE` (default `hourly`, any `OnCalendar`
expression):

```
PRIME_AGENT_SCHEDULE=daily nix run ./examples/prime-agent#schedule <dir>
```

Manage:

```
systemctl list-timers prime-agent.timer            # next activation
journalctl -u prime-agent.service                  # logs
systemd-analyze security prime-agent.service       # sandbox score
sudo systemctl stop prime-agent.timer prime-agent.service   # remove
```

The timer is transient: it does not survive a reboot — re-run the schedule
command to reinstall.

## Development

```
cd examples/prime-agent
nix develop          # shell with the bundled gems + bundix
bundix -l            # regenerate Gemfile.lock + gemset.nix after Gemfile changes
ruby main.rb "task"  # run directly, without the runner
```
