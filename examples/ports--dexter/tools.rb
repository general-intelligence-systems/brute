# frozen_string_literal: true

require "bundler/setup"
require "brute"

require_relative "tools/get_stock_price"
require_relative "tools/get_stock_prices"
require_relative "tools/get_income_statements"
require_relative "tools/get_balance_sheets"
require_relative "tools/get_cash_flow_statements"
require_relative "tools/get_all_financial_statements"
require_relative "tools/get_key_ratios"
require_relative "tools/get_company_facts"
require_relative "tools/get_company_news"
require_relative "tools/get_insider_trades"

# Financial research tools ported from virattt/dexter (src/tools/finance/).
# Tool names, descriptions, and parameter descriptions are copied verbatim
# from dexter; data comes from https://financialdatasets.ai — set
# FINANCIAL_DATASETS_API_KEY. Each tool lives in its own file under tools/,
# mirroring dexter's one-file-per-tool layout; the shared API client and
# financial-statement base class are in tools/api.rb and
# tools/statements_tool.rb.
module FinancialAgent
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
