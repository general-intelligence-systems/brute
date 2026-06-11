# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"
require "net/http"

# Financial research tools ported from virattt/dexter (src/tools/finance/).
# Tool names, descriptions, and parameter descriptions are copied verbatim
# from dexter; data comes from https://financialdatasets.ai — set
# FINANCIAL_DATASETS_API_KEY.
#
# Tools are RubyLLM::Tool subclasses, same as Brute::Tools::*.
module FinancialAgent
  # Minimal client for the Financial Datasets API (dexter's api.ts).
  module API
    BASE_URL = "https://api.financialdatasets.ai"

    def self.get(endpoint, params = {})
      uri = URI("#{BASE_URL}#{endpoint}")
      uri.query = URI.encode_www_form(params.compact) if params.compact.any?

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        request = Net::HTTP::Get.new(uri)
        request["x-api-key"] = ENV.fetch("FINANCIAL_DATASETS_API_KEY", "")
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "[Financial Datasets API] request failed: #{response.code} #{response.message} (#{endpoint})"
      end

      JSON.parse(response.body)
    end
  end

  class GetStockPrice < RubyLLM::Tool
    description "Fetches the current stock price snapshot for an equity ticker, including open, high, low, close prices, volume, and market cap."

    param :ticker, type: "string", desc: "The stock ticker symbol to fetch current price for. For example, 'AAPL' for Apple.", required: true

    def name = "get_stock_price"

    def execute(ticker:)
      data = API.get("/prices/snapshot/", ticker: ticker.strip.upcase)
      JSON.generate(data["snapshot"] || {})
    end
  end

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

  # Shared shape of the four financial statement tools (dexter's
  # FinancialStatementsInputSchema): subclasses set ENDPOINT/RESPONSE_KEY
  # and call .financial_statement_params after their description.
  class StatementsTool < RubyLLM::Tool
    def self.financial_statement_params
      param :ticker, type: "string", desc: "The stock ticker symbol to fetch financial statements for. For example, 'AAPL' for Apple.", required: true
      param :period, type: "string", desc: "The reporting period for the financial statements. 'annual' for yearly, 'quarterly' for quarterly, and 'ttm' for trailing twelve months.", required: true
      param :limit, type: "number", desc: "Maximum number of report periods to return (default: 4). Returns the most recent N periods based on the period type. Increase this for longer historical analysis when needed.", required: false
      param :report_period_gt, type: "string", desc: "Filter for financial statements with report periods after this date (YYYY-MM-DD).", required: false
      param :report_period_gte, type: "string", desc: "Filter for financial statements with report periods on or after this date (YYYY-MM-DD).", required: false
      param :report_period_lt, type: "string", desc: "Filter for financial statements with report periods before this date (YYYY-MM-DD).", required: false
      param :report_period_lte, type: "string", desc: "Filter for financial statements with report periods on or before this date (YYYY-MM-DD).", required: false
    end

    def execute(ticker:, period:, limit: 4,
                report_period_gt: nil, report_period_gte: nil,
                report_period_lt: nil, report_period_lte: nil)
      data = API.get(self.class::ENDPOINT, {
        ticker:            ticker,
        period:            period,
        limit:             limit.to_i,
        report_period_gt:  report_period_gt,
        report_period_gte: report_period_gte,
        report_period_lt:  report_period_lt,
        report_period_lte: report_period_lte,
      })
      JSON.generate(data[self.class::RESPONSE_KEY] || {})
    end
  end

  class GetIncomeStatements < StatementsTool
    ENDPOINT     = "/financials/income-statements/"
    RESPONSE_KEY = "income_statements"

    description "Fetches a company's income statements, detailing its revenues, expenses, net income, etc. over a reporting period. Useful for evaluating a company's profitability and operational efficiency."
    financial_statement_params

    def name = "get_income_statements"
  end

  class GetBalanceSheets < StatementsTool
    ENDPOINT     = "/financials/balance-sheets/"
    RESPONSE_KEY = "balance_sheets"

    description "Retrieves a company's balance sheets, providing a snapshot of its assets, liabilities, shareholders' equity, etc. at a specific point in time. Useful for assessing a company's financial position."
    financial_statement_params

    def name = "get_balance_sheets"
  end

  class GetCashFlowStatements < StatementsTool
    ENDPOINT     = "/financials/cash-flow-statements/"
    RESPONSE_KEY = "cash_flow_statements"

    description "Retrieves a company's cash flow statements, showing how cash is generated and used across operating, investing, and financing activities. Useful for understanding a company's liquidity and solvency."
    financial_statement_params

    def name = "get_cash_flow_statements"
  end

  class GetAllFinancialStatements < StatementsTool
    ENDPOINT     = "/financials/"
    RESPONSE_KEY = "financials"

    description "Retrieves all three financial statements (income statements, balance sheets, and cash flow statements) for a company in a single API call. This is more efficient than calling each statement type separately when you need all three for comprehensive financial analysis."
    financial_statement_params

    def name = "get_all_financial_statements"
  end

  class GetKeyRatios < RubyLLM::Tool
    description "Fetches the latest financial metrics snapshot for a company, including valuation ratios (P/E, P/B, P/S, EV/EBITDA, PEG), profitability (margins, ROE, ROA, ROIC), liquidity (current/quick/cash ratios), leverage (debt/equity, debt/assets), per-share metrics (EPS, book value, FCF), and growth rates (revenue, earnings, EPS, FCF, EBITDA)."

    param :ticker, type: "string", desc: "The stock ticker symbol to fetch key ratios for. For example, 'AAPL' for Apple.", required: true

    def name = "get_key_ratios"

    def execute(ticker:)
      data = API.get("/financial-metrics/snapshot/", ticker: ticker.strip.upcase)
      JSON.generate(data["snapshot"] || {})
    end
  end

  class GetCompanyFacts < RubyLLM::Tool
    description "Fetches company facts for a ticker, including name, CIK, sector, industry, market cap, number of employees, exchange, and listing details."

    param :ticker, type: "string", desc: "The stock ticker symbol to fetch company facts for. For example, 'AAPL' for Apple.", required: true

    def name = "get_company_facts"

    def execute(ticker:)
      data = API.get("/company/facts", ticker: ticker.strip.upcase)
      JSON.generate(data["company_facts"] || {})
    end
  end

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

  TOOLS = [
    GetStockPrice,
    GetStockPrices,
    GetIncomeStatements,
    GetBalanceSheets,
    GetCashFlowStatements,
    GetAllFinancialStatements,
    GetKeyRatios,
    GetCompanyFacts,
    GetCompanyNews,
    GetInsiderTrades,
  ].freeze
end
