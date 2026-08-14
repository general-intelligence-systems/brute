# frozen_string_literal: true

require_relative "api"

module FinancialAgent
  class GetCompanyFacts < RubyLLM::Tool
    description "Fetches company facts for a ticker, including name, CIK, sector, industry, market cap, number of employees, exchange, and listing details."

    param :ticker, type: "string", desc: "The stock ticker symbol to fetch company facts for. For example, 'AAPL' for Apple.", required: true

    def name = "get_company_facts"

    def execute(ticker:)
      data = API.get("/company/facts", ticker: ticker.strip.upcase)
      JSON.generate(data["company_facts"] || {})
    end
  end
end
