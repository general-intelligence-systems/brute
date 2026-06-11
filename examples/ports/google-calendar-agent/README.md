# Calendar Agent

A provider-agnostic calendar agent ported from
**[inference-gateway/google-calendar-agent](https://github.com/inference-gateway/google-calendar-agent)**.

The system prompt, tool descriptions, parameter texts, slot-finding algorithm,
and the `schedule-meeting` skill are copied verbatim from the source — with
"Google Calendar" generalized to the injected provider's display name.

## Layout

| File | Role |
|------|------|
| `agent.rb` | prompt + wiring (run this) |
| `tools.rb` | the upstream tool set, defined against the Provider interface |
| `provider.rb` | the provider adapter interface |
| `providers/google_calendar.rb` | reference adapter (Calendar v3 REST API) |
| `providers/in_memory.rb` | the upstream's "mock mode" — runs with no credentials |
| `.brute/skills/schedule-meeting/` | upstream skill, verbatim |

To support another backend (CalDAV, Office 365, ...), copy
`providers/google_calendar.rb` and implement the same methods.

## Usage

```sh
export ANTHROPIC_API_KEY=...

# demo mode (in-memory provider, no credentials needed):
bundle exec ruby examples/ports/google-calendar-agent/agent.rb "What's on my calendar today?"

# against real Google Calendar:
export GOOGLE_CALENDAR_ACCESS_TOKEN=$(gcloud auth print-access-token \
  --scopes=https://www.googleapis.com/auth/calendar)
export GOOGLE_CALENDAR_ID=primary
bundle exec ruby examples/ports/google-calendar-agent/agent.rb "Schedule a 30-min sync tomorrow morning"
```
