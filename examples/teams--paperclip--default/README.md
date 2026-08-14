# Default

The default agent templates from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`default`](https://github.com/paperclipai/companies/tree/main/default)).

Unlike every other company in the catalog, `default` is not an org chart — it
is two standalone agent templates in the **workspace format**, where an agent
is four sibling markdown files instead of a single `AGENTS.md`:

| File | Role |
|------|------|
| `AGENTS.md` | entrypoint instructions |
| `SOUL.md` | who the agent is and how it should act |
| `TOOLS.md` | tools the agent knows it has |
| `HEARTBEAT.md` | checklist the agent runs every time it wakes |

Both templates (`ceo/` and `default/`) are copied verbatim. `agent.rb` builds
a single `Brute::Agent` whose system prompt is the four files concatenated.

Note: the upstream files reference the Paperclip control plane (its task API,
`paperclip` skill, and `$AGENT_HOME` conventions), which has no counterpart
here — they are kept verbatim as written, and the agent treats them as
descriptive context.

## Usage

```sh
export ANTHROPIC_API_KEY=...

bundle exec ruby examples/ports/paperclip/default/agent.rb ceo "<task>"
bundle exec ruby examples/ports/paperclip/default/agent.rb default "<task>"
```
