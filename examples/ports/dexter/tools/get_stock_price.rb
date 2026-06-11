# frozen_string_literal: true

require_relative "api"

module FinancialAgent
  class GetStockPrice < RubyLLM::Tool
    description "Fetches the current stock price snapshot for an equity ticker, including open, high, low, close prices, volume, and market cap."

    param :ticker, type: "string", desc: "The stock ticker symbol to fetch current price for. For example, 'AAPL' for Apple.", required: true

    def name = "get_stock_price"

    def execute(ticker:)
      data = API.get("/prices/snapshot/", ticker: ticker.strip.upcase)
      JSON.generate(data["snapshot"] || {})
    end
  end
end
