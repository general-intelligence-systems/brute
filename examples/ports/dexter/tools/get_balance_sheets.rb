# frozen_string_literal: true

require_relative "statements_tool"

module FinancialAgent
  class GetBalanceSheets < StatementsTool
    ENDPOINT     = "/financials/balance-sheets/"
    RESPONSE_KEY = "balance_sheets"

    description "Retrieves a company's balance sheets, providing a snapshot of its assets, liabilities, shareholders' equity, etc. at a specific point in time. Useful for assessing a company's financial position."
    financial_statement_params

    def name = "get_balance_sheets"
  end
end
