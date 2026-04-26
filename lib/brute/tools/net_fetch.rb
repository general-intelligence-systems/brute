# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

require "net/http"
require "uri"

module Brute
  module Tools
    class NetFetch < RubyLLM::Tool
      description "Fetch content from a URL. Returns the response body as text."

      param :url, type: 'string', desc: "The URL to fetch", required: true

      def name; "fetch"; end

      MAX_BODY = 50_000
      TIMEOUT = 30

      def execute(url:)
        uri = URI.parse(url)
        raise "Invalid URL scheme: #{uri.scheme}" unless %w[http https].include?(uri.scheme)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "forge-rb/1.0"

        response = http.request(request)
        body = response.body.to_s
        body = body[0...MAX_BODY] + "\n...(truncated)" if body.size > MAX_BODY

        {status: response.code.to_i, body: body, content_type: response["content-type"]}
      end
    end
  end
end
