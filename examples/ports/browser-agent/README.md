# Browser Agent

A browser automation agent ported from
**[inference-gateway/browser-agent](https://github.com/inference-gateway/browser-agent)**.

The system prompt, tool descriptions, parameter texts, and the four skills
(`web-scraping`, `form-automation`, `webapp-testing`, `deep-research`) are
copied verbatim from the source. Upstream drives Playwright; this port runs
through a swappable Driver interface with a Chrome-over-CDP reference
implementation (the [ferrum](https://github.com/rubycdp/ferrum) gem).

## Layout

| File | Role |
|------|------|
| `agent.rb` | prompt + wiring (run this) |
| `tools.rb` | the upstream tool set (browser tools + the HTTP `Fetch` tool) |
| `driver.rb` | the browser driver interface |
| `drivers/ferrum.rb` | reference driver (Chrome via CDP) |
| `.brute/skills/*/` | upstream skills, verbatim |

Upstream's `Read`/`Write`/`Edit` file tools map to brute's own
`FSRead`/`FSWrite`/`FSPatch` (see `agent.rb`). To use another engine
(Selenium, playwright-ruby-client, ...), copy `drivers/ferrum.rb` and
implement the same methods.

## Usage

```sh
bundle config set --local with browser && bundle install   # installs ferrum
export ANTHROPIC_API_KEY=...

bundle exec ruby examples/ports/browser-agent/agent.rb \
  "Open https://news.ycombinator.com and extract the top 5 story titles"
```

`HEADLESS=false` shows the browser window. The `Fetch` tool is configured via
`FETCH_ALLOWED_DOMAINS`, `FETCH_MAX_BYTES`, `FETCH_ALLOW_DOWNLOADS`, and
`FETCH_DOWNLOAD_DIR`.
