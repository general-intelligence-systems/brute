# Examples

Four categories:

- **[agents](agents/)** — single agents: *prompt + tools + skills*. The
  numbered walkthroughs live here.
- **[teams](teams/)** — agents wired together (a lead agent delegating to
  `Brute::Tools::SubAgent` specialists). Nothing original here yet — see
  [ports/paperclip](ports/paperclip/) for a ported team.
- **[workflows](workflows/)** — nothing here yet.
- **[ports](ports/)** — agents and teams ported from other projects, one
  directory per source:

  | Port | Source |
  |------|--------|
  | [ports/dexter](ports/dexter/) | [virattt/dexter](https://github.com/virattt/dexter) |
  | [ports/google-calendar-agent](ports/google-calendar-agent/) | [inference-gateway/google-calendar-agent](https://github.com/inference-gateway/google-calendar-agent) |
  | [ports/grafana-agent](ports/grafana-agent/) | [inference-gateway/grafana-agent](https://github.com/inference-gateway/grafana-agent) |
  | [ports/browser-agent](ports/browser-agent/) | [inference-gateway/browser-agent](https://github.com/inference-gateway/browser-agent) |
  | [ports/openfang](ports/openfang/) | [RightNow-AI/openfang](https://github.com/RightNow-AI/openfang) |
  | [ports/paperclip](ports/paperclip/) | [paperclipai/companies](https://github.com/paperclipai/companies) |

Prompts and tool descriptions in ports are verbatim from their sources; each
port's README links the project it's based on.
