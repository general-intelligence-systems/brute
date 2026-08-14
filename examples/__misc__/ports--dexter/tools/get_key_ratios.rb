# frozen_string_literal: true

require_relative "api"

module FinancialAgent
  class GetKeyRatios < RubyLLM::Tool
    description "Fetches the latest financial metrics snapshot for a company, including valuation ratios (P/E, P/B, P/S, EV/EBITDA, PEG), profitability (margins, ROE, ROA, ROIC), liquidity (current/quick/cash ratios), leverage (debt/equity, debt/assets), per-share metrics (EPS, book value, FCF), and growth rates (revenue, earnings, EPS, FCF, EBITDA)."

    param :ticker, type: "string", desc: "The stock ticker symbol to fetch key ratios for. For example, 'AAPL' for Apple.", required: true

    def name = "get_key_ratios"

    def execute(ticker:)
      data = API.get("/financial-metrics/snapshot/", ticker: ticker.strip.upcase)
      JSON.generate(data["snapshot"] || {})
    end
  end
end
