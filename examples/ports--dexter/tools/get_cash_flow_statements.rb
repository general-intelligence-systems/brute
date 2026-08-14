# frozen_string_literal: true

require_relative "statements_tool"

module FinancialAgent
  class GetCashFlowStatements < StatementsTool
    ENDPOINT     = "/financials/cash-flow-statements/"
    RESPONSE_KEY = "cash_flow_statements"

    description "Retrieves a company's cash flow statements, showing how cash is generated and used across operating, investing, and financing activities. Useful for understanding a company's liquidity and solvency."
    financial_statement_params

    def name = "get_cash_flow_statements"
  end
end
