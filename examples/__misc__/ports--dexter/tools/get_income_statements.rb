# frozen_string_literal: true

require_relative "statements_tool"

module FinancialAgent
  class GetIncomeStatements < StatementsTool
    ENDPOINT     = "/financials/income-statements/"
    RESPONSE_KEY = "income_statements"

    description "Fetches a company's income statements, detailing its revenues, expenses, net income, etc. over a reporting period. Useful for evaluating a company's profitability and operational efficiency."
    financial_statement_params

    def name = "get_income_statements"
  end
end
