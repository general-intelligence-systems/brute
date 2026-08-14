# frozen_string_literal: true

require_relative "api"

module FinancialAgent
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
end
