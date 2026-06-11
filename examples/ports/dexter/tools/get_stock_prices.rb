# frozen_string_literal: true

require_relative "api"

module FinancialAgent
  class GetStockPrices < RubyLLM::Tool
    description "Retrieves historical price data for a stock over a specified date range, including open, high, low, close prices and volume."

    param :ticker, type: "string", desc: "The stock ticker symbol to fetch historical prices for. For example, 'AAPL' for Apple.", required: true
    param :interval, type: "string", desc: "The time interval for price data. Defaults to 'day'.", required: false
    param :start_date, type: "string", desc: "Start date in YYYY-MM-DD format. Required.", required: true
    param :end_date, type: "string", desc: "End date in YYYY-MM-DD format. Required.", required: true

    def name = "get_stock_prices"

    def execute(ticker:, start_date:, end_date:, interval: "day")
      data = API.get("/prices/",
                     ticker: ticker.strip.upcase, interval: interval,
                     start_date: start_date, end_date: end_date)
      JSON.generate(data["prices"] || [])
    end
  end
end
