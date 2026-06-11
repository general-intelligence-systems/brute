# Grafana Agent

A Grafana dashboarding agent ported from
**[inference-gateway/grafana-agent](https://github.com/inference-gateway/grafana-agent)**.

The system prompt, tool descriptions, parameter texts, the PromQL suggestion
generators (per metric type), and the `dashboarding` / `promql` skills are
copied verbatim from the source.

## Layout

| File | Role |
|------|------|
| `agent.rb` | prompt + wiring (run this) |
| `tools.rb` | the upstream tool set + ported `internal/promql` suggestion logic |
| `.brute/skills/dashboarding/`, `.brute/skills/promql/` | upstream skills, verbatim |

## Usage

```sh
export ANTHROPIC_API_KEY=...
export PROMETHEUS_URL=http://localhost:9090
export GRAFANA_URL=http://localhost:3000
export GRAFANA_API_KEY=...               # service account token
export GRAFANA_DEPLOY_ENABLED=true       # required before deploys (same gate as upstream)

bundle exec ruby examples/ports/grafana-agent/agent.rb \
  "Discover the http metrics and build a latency dashboard for them"
```
