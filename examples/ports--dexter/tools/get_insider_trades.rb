# frozen_string_literal: true

require_relative "api"

module FinancialAgent
  class GetInsiderTrades < RubyLLM::Tool
    description "Retrieves insider trading transactions for a given company ticker. Insider trades include purchases and sales of company stock by executives, directors, and other insiders. This data is sourced from SEC Form 4 filings. Use filing_date filters to narrow down results by date range. Use the name parameter to filter by a specific insider."

    param :ticker, type: "string", desc: "The stock ticker symbol to fetch insider trades for. For example, 'AAPL' for Apple.", required: true
    param :limit, type: "number", desc: "Maximum number of insider trades to return (default: 10, max: 1000). Increase this for longer historical windows when needed.", required: false
    param :filing_date, type: "string", desc: "Exact filing date to filter by (YYYY-MM-DD).", required: false
    param :filing_date_gte, type: "string", desc: "Filter for trades with filing date greater than or equal to this date (YYYY-MM-DD).", required: false
    param :filing_date_lte, type: "string", desc: "Filter for trades with filing date less than or equal to this date (YYYY-MM-DD).", required: false
    param :filing_date_gt, type: "string", desc: "Filter for trades with filing date greater than this date (YYYY-MM-DD).", required: false
    param :filing_date_lt, type: "string", desc: "Filter for trades with filing date less than this date (YYYY-MM-DD).", required: false
    param :name, type: "string", desc: "Filter by insider name (e.g., 'HUANG JEN HSUN'). Names can be discovered via the /insider-trades/names/?ticker={ticker} endpoint.", required: false

    def name = "get_insider_trades"

    def execute(ticker:, limit: 10, filing_date: nil, filing_date_gte: nil,
                filing_date_lte: nil, filing_date_gt: nil, filing_date_lt: nil, name: nil)
      data = API.get("/insider-trades/", {
        ticker:          ticker.upcase,
        limit:           limit.to_i,
        filing_date:     filing_date,
        filing_date_gte: filing_date_gte,
        filing_date_lte: filing_date_lte,
        filing_date_gt:  filing_date_gt,
        filing_date_lt:  filing_date_lt,
        name:            name,
      })
      JSON.generate(data["insider_trades"] || [])
    end
  end
end
