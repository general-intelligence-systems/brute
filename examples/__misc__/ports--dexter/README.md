# Financial Agent

A financial research agent ported from **[virattt/dexter](https://github.com/virattt/dexter)**.

The system prompt (dexter's CLI channel profile), tool descriptions, and the
bundled `dcf-valuation` skill are copied verbatim from the source. Data comes
from the [Financial Datasets API](https://financialdatasets.ai).

## Layout

| File | Role |
|------|------|
| `agent.rb` | prompt + wiring (run this) |
| `tools.rb` | requires the tools and assembles the `TOOLS` array |
| `tools/` | one file per finance tool (`RubyLLM::Tool` subclasses), plus the shared `api.rb` client and `statements_tool.rb` base — mirrors dexter's `src/tools/finance/` |
| `.brute/skills/dcf-valuation/` | dexter's DCF skill + sector WACC reference |

## Usage

```sh
export FINANCIAL_DATASETS_API_KEY=...   # https://financialdatasets.ai
export ANTHROPIC_API_KEY=...

bundle exec ruby examples/ports/dexter/agent.rb \
  "How did NVDA's margins trend over the last 3 years?"
```
