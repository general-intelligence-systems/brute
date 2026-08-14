# frozen_string_literal: true

# OpenFang's web_search tool, ported from RightNow-AI/openfang
# crates/openfang-runtime/src/tool_runner.rs — tool name, description,
# parameter schema, and result formatting are verbatim. The behavior ports
# openfang's own DuckDuckGo HTML fallback path (tool_web_search_legacy +
# web_search.rs parse_ddg_results), including the result parsing.
#
# Set SEARXNG_URL (e.g. http://localhost:8888) to search a self-hosted
# SearXNG instance instead of DuckDuckGo.

require "bundler/setup"
require "brute"

require "cgi"
require "json"
require "net/http"
require "uri"

module OpenFang
  module Tools
    class WebSearch < RubyLLM::Tool
      description "Search the web using multiple providers (Tavily, Brave, Perplexity, DuckDuckGo) with automatic fallback. Returns structured results with titles, URLs, and snippets."

      param :query, type: 'string', desc: "The search query", required: true
      param :max_results, type: 'integer', desc: "Maximum number of results to return (default: 5, max: 20)", required: false

      def name; "web_search"; end

      TIMEOUT = 15
      USER_AGENT = "Mozilla/5.0 (compatible; OpenFangAgent/0.1)"
      MAX_REDIRECTS = 3

      def execute(query:, max_results: nil)
        max = (max_results || 5).to_i.clamp(1, 20)

        results = if ENV["SEARXNG_URL"]
          searxng_results(query, max)
        else
          ddg_results(query, max)
        end

        return "No results found for '#{query}'." if results.empty?

        output = +"Search results for '#{query}':\n\n"
        results.each_with_index do |(title, url, snippet), i|
          output << "#{i + 1}. #{title}\n   URL: #{url}\n   #{snippet}\n\n"
        end
        output
      rescue => error
        "Search request failed: #{error.message}"
      end

      private

        def searxng_results(query, max)
          base = ENV.fetch("SEARXNG_URL").chomp("/")
          uri = URI("#{base}/search")
          uri.query = URI.encode_www_form(q: query, format: "json")

          payload = JSON.parse(get(uri))
          Array(payload["results"]).first(max).map do |r|
            [r["title"].to_s, r["url"].to_s, r["content"].to_s]
          end
        end

        def ddg_results(query, max)
          uri = URI("https://html.duckduckgo.com/html/")
          uri.query = URI.encode_www_form(q: query)
          parse_ddg_results(get(uri), max)
        end

        def get(uri, redirects_left = MAX_REDIRECTS)
          response = Net::HTTP.start(
            uri.host, uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: TIMEOUT, read_timeout: TIMEOUT,
          ) do |http|
            request = Net::HTTP::Get.new(uri)
            request["User-Agent"] = USER_AGENT
            http.request(request)
          end

          if response.is_a?(Net::HTTPRedirection) && redirects_left.positive?
            return get(URI.join(uri, response["location"]), redirects_left - 1)
          end

          response.body.to_s
        end

        # Straight port of openfang's parse_ddg_results (web_search.rs).
        def parse_ddg_results(html, max)
          results = []

          html.split('class="result__a"').each do |chunk|
            break if results.size >= max
            next unless chunk.include?("href=")

            url = extract_between(chunk, 'href="', '"').to_s
            actual_url = if url.include?("uddg=")
              encoded = url.split("uddg=", 2).last.split("&").first
              encoded ? CGI.unescape(encoded) : url
            else
              url
            end

            title = strip_html_tags(extract_between(chunk, ">", "</a>").to_s)

            snippet = ""
            if (snip_start = chunk.index('class="result__snippet"'))
              after = chunk[snip_start..]
              raw = extract_between(after, ">", "</a>") || extract_between(after, ">", "</")
              snippet = strip_html_tags(raw.to_s)
            end

            results << [title, actual_url, snippet] unless title.empty? || actual_url.empty?
          end

          results
        end

        def extract_between(text, start_marker, end_marker)
          start_idx = text.index(start_marker) or return nil
          remaining = text[(start_idx + start_marker.length)..]
          end_idx = remaining.index(end_marker) or return nil
          remaining[...end_idx]
        end

        def strip_html_tags(text)
          text.gsub(/<[^>]*>?/, "")
              .gsub("&amp;", "&")
              .gsub("&lt;", "<")
              .gsub("&gt;", ">")
              .gsub("&quot;", '"')
              .gsub("&#x27;", "'")
              .gsub("&nbsp;", " ")
              .gsub("&#39;", "'")
        end
    end
  end
end
