# frozen_string_literal: true

require "json"
require_relative "web_http"
require_relative "html_markdown"

# web_fetch — picoclaw `pkg/tools/integration/web.go` (WebFetchTool).
# http/https only; SSRF guards (pre-flight + per-redirect + connect-time IP
# filtering, private_host_whitelist); <=5 redirects; 60s timeout; body capped
# at tools.web.fetch_limit_bytes (10MB); Cloudflare `cf-mitigated: challenge`
# 403 retried once with an honest UA; extractors json / text / markdown
# (tools.web.format) / raw; result JSON {extractor,length,status,text,
# truncated,url} (Go sorts map keys on marshal).
class WebFetch < Brute::Tool
  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  HONEST_UA = "picoclaw/0.1.0 (+https://github.com/sipeed/picoclaw; AI assistant bot)"
  DEFAULT_MAX_CHARS = 50_000
  MAX_REDIRECTS = 5
  FETCH_TIMEOUT = 60

  RE_SCRIPT = /<script[\s\S]*?<\/script>/
  RE_STYLE = /<style[\s\S]*?<\/style>/
  RE_TAGS = /<[^>]+>/
  RE_WHITESPACE = /[^\S\n]+/
  RE_BLANK_LINES = /\n{3,}/

  description "Fetch a URL and extract readable content (HTML to text). Use this to get weather " \
              "info, news, articles, or any web content."
  params({
    "type" => "object",
    "properties" => {
      "url" => { "type" => "string", "description" => "URL to fetch" },
      "maxChars" => { "type" => "integer", "minimum" => 100, "description" => "Maximum characters to extract" },
    },
    "required" => ["url"],
  })

  def initialize(max_chars: DEFAULT_MAX_CHARS, format: "plaintext", fetch_limit_bytes: 10 * 1024 * 1024,
                 proxy: nil, private_host_whitelist: [], allow_private: false)
    @max_chars = max_chars.to_i.positive? ? max_chars.to_i : DEFAULT_MAX_CHARS
    @format = format.to_s
    @fetch_limit_bytes = fetch_limit_bytes.to_i.positive? ? fetch_limit_bytes.to_i : 10 * 1024 * 1024
    @proxy = proxy.to_s.empty? ? nil : proxy
    @whitelist = WebHttp::Whitelist.build(private_host_whitelist)
    @allow_private = allow_private
  end

  def name = "web_fetch"

  def execute(**args)
    url = args[:url]
    return "url is required" unless url.is_a?(String)

    begin
      parsed = URI.parse(url)
    rescue URI::InvalidURIError => e
      return "invalid URL: #{e.message}"
    end
    return "only http/https URLs are allowed" unless %w[http https].include?(parsed.scheme)
    return "missing domain in URL" if parsed.host.to_s.empty?

    if WebHttp.obvious_private_host?(parsed.host, @whitelist, allow_private: @allow_private)
      return "fetching private or local network hosts is not allowed"
    end

    max_chars = @max_chars
    mc = args[:maxChars]
    max_chars = mc.to_i if mc.is_a?(Numeric) && mc.to_i > 100

    begin
      response, body = fetch_once(url, USER_AGENT)
      if response.code.to_i == 403 && response["cf-mitigated"] == "challenge"
        response, body = fetch_once(url, HONEST_UA) # WAF bot challenge: retry honestly, once
      end
    rescue WebHttp::Error => e
      return e.message
    end

    media_type = response["content-type"].to_s.split(";").first.to_s.strip
    media_type = "application/octet-stream" if media_type.empty? # security fallback (upstream)

    text = nil
    extractor = nil
    case media_type
    when "application/json"
      begin
        text = JSON.pretty_generate(deep_sort(JSON.parse(body)))
        extractor = "json"
      rescue JSON::ParserError
        text = body
        extractor = "raw"
      end
    when "text/html"
      text, extractor = extract_html(body)
      return text if extractor.nil? # markdown conversion failure message
    else
      if looks_like_html?(body)
        text, extractor = extract_html(body)
        return text if extractor.nil?
      else
        text = body
        extractor = "raw"
      end
    end

    truncated = text.bytesize > max_chars
    text = "#{text.byteslice(0, max_chars)}\n[Content truncated due to size limit]" if truncated

    result = {
      "extractor" => extractor,
      "length" => text.bytesize,
      "status" => response.code.to_i,
      "text" => text.force_encoding(Encoding::UTF_8).scrub,
      "truncated" => truncated,
      "url" => url,
    }
    JSON.pretty_generate(result)
  rescue StandardError => e
    warn("web_fetch crashed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    e.message
  end

  private

  def fetch_once(url, user_agent)
    WebHttp.get(url, headers: { "User-Agent" => user_agent }, timeout: FETCH_TIMEOUT,
                     proxy: @proxy, max_redirects: MAX_REDIRECTS, max_bytes: @fetch_limit_bytes,
                     whitelist: @whitelist, allow_private: @allow_private)
  end

  def looks_like_html?(body)
    return false if body.empty?

    body.start_with?("<!doctype") || body.downcase.start_with?("<html")
  end

  def extract_html(body)
    if @format.downcase == "markdown"
      begin
        [HtmlMarkdown.convert(body), "markdown"]
      rescue StandardError => e
        ["failed to HTML to markdown: #{e.message}", nil]
      end
    else
      [extract_text(body), "text"]
    end
  end

  def extract_text(html)
    result = html.gsub(RE_SCRIPT, "").gsub(RE_STYLE, "").gsub(RE_TAGS, "")
    result = result.strip.gsub(RE_WHITESPACE, " ").gsub(RE_BLANK_LINES, "\n\n")
    result.split("\n").map(&:strip).reject(&:empty?).join("\n")
  end

  # Go's json.MarshalIndent sorts map keys; Ruby preserves insertion order.
  def deep_sort(obj)
    case obj
    when Hash
      obj.keys.sort.each_with_object({}) { |k, acc| acc[k] = deep_sort(obj[k]) }
    when Array
      obj.map { |v| deep_sort(v) }
    else
      obj
    end
  end
end
