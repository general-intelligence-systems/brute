# frozen_string_literal: true

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
end
