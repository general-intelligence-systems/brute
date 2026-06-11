# Financial Agent

A financial research agent ported from **[virattt/dexter](https://github.com/virattt/dexter)**.

The system prompt (dexter's CLI channel profile), tool descriptions, and the
bundled `dcf-valuation` skill are copied verbatim from the source. Data comes
from the [Financial Datasets API](https://financialdatasets.ai).

## Layout

| File | Role |
|------|------|
| `agent.rb` | prompt + wiring (run this) |
| `tools.rb` | dexter's finance tools as `RubyLLM::Tool` subclasses |
| `.brute/skills/dcf-valuation/` | dexter's DCF skill + sector WACC reference |

## Usage

```sh
export FINANCIAL_DATASETS_API_KEY=...   # https://financialdatasets.ai
export ANTHROPIC_API_KEY=...

bundle exec ruby examples/agents/financial_agent/agent.rb \
  "How did NVDA's margins trend over the last 3 years?"
```
