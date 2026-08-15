# frozen_string_literal: true

require "net/http"
require "uri"
require "cgi"
require "json"

module HermesTools
  # web_extract — fetch URLs and extract readable text. Port of hermes-agent
  # tools/web_tools.py web_extract: up to 5 urls, char_limit (min 2000,
  # default 15000) per page.
  class WebExtract < Brute::Tool
    description "Fetch web pages and extract their text content."
    params({
      "type" => "object",
      "properties" => {
        "urls" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Up to 5 URLs to fetch" },
        "char_limit" => { "type" => "integer", "description" => "Max characters of text per page (min 2000, default 15000)", "default" => 15_000 },
      },
      "required" => ["urls"],
    })

    MAX_URLS = 5

    def name = "web_extract"

    def execute(urls:, char_limit: 15_000, **_rest)
      urls = Array(urls).first(MAX_URLS)
      return err("urls is required (up to #{MAX_URLS})") if urls.empty?

      char_limit = [char_limit.to_i, 2_000].max
      results = urls.map { |u| extract(u, char_limit) }
      JSON.dump("results" => results)
    end

    private

    def extract(url, char_limit)
      uri = URI.parse(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                               open_timeout: 10, read_timeout: 20) do |http|
        http.get(uri.request_uri.empty? ? "/" : uri.request_uri,
                 { "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) hermes-brute" })
      end
      return { "url" => url, "error" => "HTTP #{response.code}" } unless response.is_a?(Net::HTTPSuccess)

      text = html_to_text(response.body)
      truncated = text.length > char_limit
      text = text[0, char_limit]
      { "url" => url, "content" => text, "truncated" => truncated }
    rescue StandardError => e
      { "url" => url, "error" => "#{e.class}: #{e.message}" }
    end

    def html_to_text(html)
      text = html.gsub(%r{<(script|style)[^>]*>.*?</\1>}mi, " ")
      text = text.gsub(/<br\s*\/?>/i, "\n")
      text = text.gsub(%r{</(p|div|li|h[1-6]|tr)>}i, "\n")
      text = text.gsub(/<[^>]+>/, " ")
      CGI.unescapeHTML(text).lines.map { |l| l.gsub(/\s+/, " ").strip }.reject(&:empty?).join("\n")
    end

    def err(message)
      JSON.dump("error" => message)
    end
  end
end
