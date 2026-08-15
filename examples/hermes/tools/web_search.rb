# frozen_string_literal: true

require "net/http"
require "uri"
require "cgi"
require "json"

module HermesTools
  # web_search — DuckDuckGo fallback (same approach as picoclaw). Port of
  # hermes-agent tools/web_tools.py web_search (backend: duckduckgo html).
  class WebSearch < Brute::Tool
    description "Search the web and return titles, URLs and snippets."
    params({
      "type" => "object",
      "properties" => {
        "query" => { "type" => "string", "description" => "The search query" },
        "limit" => { "type" => "integer", "description" => "Maximum results to return (default 5)", "default" => 5 },
      },
      "required" => ["query"],
    })

    def name = "web_search"

    def execute(query:, limit: 5, **_rest)
      uri = URI("https://html.duckduckgo.com/html/?q=#{URI.encode_www_form_component(query)}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
        http.get(uri.request_uri, { "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) hermes-brute" })
      end
      return err("web_search failed: HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)

      results = parse_results(response.body).first(limit.to_i <= 0 ? 5 : limit.to_i)
      return JSON.dump("results" => [], "note" => "No results for #{query.inspect}") if results.empty?

      JSON.dump("results" => results.each_with_index.map { |r, i| r.merge("position" => i + 1) })
    rescue StandardError => e
      err("web_search failed: #{e.class}: #{e.message}")
    end

    private

    def parse_results(html)
      links = html.scan(%r{<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>}m)
      snippets = html.scan(%r{<a[^>]*class="result__snippet"[^>]*>(.*?)</a>}m).map(&:first)
      links.zip(snippets).filter_map do |(href, title), snippet|
        next unless href

        { "title" => clean(title), "url" => unwrap(href), "snippet" => clean(snippet.to_s) }
      end
    end

    # DuckDuckGo wraps targets as //duckduckgo.com/l/?uddg=<urlencoded>
    def unwrap(href)
      match = href.match(/[?&]uddg=([^&]+)/)
      match ? URI.decode_www_form_component(match[1]) : href
    end

    def clean(html)
      CGI.unescapeHTML(html.gsub(/<[^>]+>/, "")).gsub(/\s+/, " ").strip
    end

    def err(message)
      JSON.dump("error" => message)
    end
  end
end
