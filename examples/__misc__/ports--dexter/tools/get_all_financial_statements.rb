# frozen_string_literal: true

require_relative "statements_tool"

module FinancialAgent
  class GetAllFinancialStatements < StatementsTool
    ENDPOINT     = "/financials/"
    RESPONSE_KEY = "financials"

    description "Retrieves all three financial statements (income statements, balance sheets, and cash flow statements) for a company in a single API call. This is more efficient than calling each statement type separately when you need all three for comprehensive financial analysis."
    financial_statement_params

    def name = "get_all_financial_statements"
  end
end
