# frozen_string_literal: true

require_relative "api"

module FinancialAgent
  class GetCompanyNews < RubyLLM::Tool
    description "Retrieves recent news headlines, including title, source, publication date, and URL. Pass a ticker for company-specific news, or omit the ticker for broad market news covering macro, rates, earnings, geopolitics, and more. Also useful when trying to explain broad price moves — omit the ticker to check for market-wide catalysts."

    param :ticker, type: "string", desc: "The stock ticker symbol (e.g., 'AAPL'). Omit for broad market news.", required: false
    param :limit, type: "number", desc: "Maximum number of news articles to return (default: 5, max: 10).", required: false

    def name = "get_company_news"

    def execute(ticker: nil, limit: 5)
      data = API.get("/news", ticker: ticker&.strip&.upcase, limit: [limit.to_i, 10].min)
      JSON.generate(data["news"] || [])
    end
  end
end
