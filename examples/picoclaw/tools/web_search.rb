# frozen_string_literal: true

require "json"
require "cgi"
require_relative "web_http"

# web_search — picoclaw `pkg/tools/integration/web.go` (WebSearchTool + the ten
# providers). Multi-provider with per-query resolution: explicit
# tools.web.provider when ready, else the auto order perplexity, brave, kagi,
# searxng, tavily, gemini, then sogou/duckduckgo by query script (Han →
# sogou, Latin → duckduckgo), then baidu_search/glm_search. Key-gated
# providers rotate keys round-robin and advance on 401/403/429/5xx.
# With no provider ready the tool is unregistered (main.rb mirrors
# NewWebSearchTool returning nil).
class WebSearch < Brute::Tool
  SEARCH_TIMEOUT = 10
  SLOW_TIMEOUT = 30 # perplexity + baidu (LLM-backed)
  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  SOGOU_USER_AGENT = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
  HONEST_UA = "picoclaw/0.1.0 (+https://github.com/sipeed/picoclaw; AI assistant bot)"

  KNOWN_PROVIDERS = %w[sogou duckduckgo gemini brave tavily kagi perplexity searxng glm_search baidu_search].freeze
  AUTO_PRIMARY = %w[perplexity brave kagi searxng tavily gemini].freeze
  AUTO_FALLBACK = %w[baidu_search glm_search].freeze

  RE_TAGS = /<[^>]+>/
  RE_DDG_LINK = /<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/
  RE_DDG_SNIPPET = /<a class="result__snippet[^"]*".*?>([\s\S]*?)<\/a>/
  RE_SOGOU_TITLE = /<a\s+class="?resultLink"?\s+href="([^"]+)"[^>]*id="sogou_vr_\d+_\d+"[^>]*>\s*(.*?)\s*<\/a>/
  RE_SOGOU_SNIPPET = /<div class="clamp\d*[^"]*">\s*(.*?)\s*<\/div>/
  RE_SOGOU_REAL_URL = /url=([^&]+)/

  description "Search the web for current information. Supports query, count, and an optional " \
              "temporal range filter. Returns titles, URLs, and snippets from search results."
  params({
    "type" => "object",
    "properties" => {
      "query" => { "type" => "string", "description" => "Search query" },
      "count" => { "type" => "integer", "description" => "Number of results (default: 10, max: 10)", "minimum" => 1, "maximum" => 10 },
      "range" => { "type" => "string", "description" => "Optional time filter: d (day), w (week), m (month), y (year)", "enum" => %w[d w m y] },
    },
    "required" => ["query"],
  })

  # Round-robin API key pool (APIKeyPool port).
  class KeyPool
    def initialize(keys)
      @keys = keys || []
      @current = -1
    end

    def empty? = @keys.empty?

    # Each iterator starts at the next slot and walks the pool at most once.
    def each
      return enum_for(:each) unless block_given?
      return if @keys.empty?

      start = (@current += 1)
      @keys.size.times do |attempt|
        yield @keys[(start + attempt) % @keys.size]
      end
    end
  end

  module RangeMaps
    module_function

    def normalize(raw)
      code = raw.to_s.strip.downcase
      return code if ["", "d", "w", "m", "y"].include?(code)

      raise ArgumentError, "range must be one of: d, w, m, y"
    end

    def brave(code) = { "d" => "pd", "w" => "pw", "m" => "pm", "y" => "py" }[code].to_s
    def tavily(code) = { "d" => "day", "w" => "week", "m" => "month", "y" => "year" }[code].to_s
    def perplexity(code) = tavily(code)
    def duckduckgo(code) = { "d" => "d", "w" => "w", "m" => "m", "y" => "t" }[code].to_s
    def searxng(code) = tavily(code)
    def glm(code) = { "d" => "oneDay", "w" => "oneWeek", "m" => "oneMonth", "y" => "oneYear" }[code] || "noLimit"

    def baidu(code)
      { "d" => "week", "w" => "week", "m" => "month", "y" => "year" }[code].to_s
    end

    def kagi_lens(code)
      case code
      when "d" then { "time_relative" => "day" }
      when "w" then { "time_relative" => "week" }
      when "m" then { "time_relative" => "month" }
      when "y" then { "time_after" => (Time.now.utc - 365 * 86_400).strftime("%Y-%m-%d") }
      end
    end

    def sogou_hint(query, code)
      suffix = { "d" => " 最近一天", "w" => " 最近一周", "m" => " 最近一个月", "y" => " 最近一年" }[code]
      suffix ? query + suffix : query
    end
  end

  # --- providers ---------------------------------------------------------------

  module Providers
    module_function

    def format_items(query, items, via: nil)
      return "No results for: #{query}" if items.empty?

      header = via ? "Results for: #{query} (via #{via})" : "Results for: #{query}"
      lines = [header]
      items.each_with_index do |item, i|
        lines << "#{i + 1}. #{item[:title]}\n   #{item[:url]}"
        lines << "   Published: #{item[:published]}" if item[:published] && !item[:published].empty?
        lines << "   #{item[:snippet]}" if item[:snippet] && !item[:snippet].empty?
      end
      lines.join("\n")
    end

    def clean_text(content) = content.gsub(RE_TAGS, "").then { |s| CGI.unescapeHTML(s) }.strip

    def brave(query, count, range_code, keys:, proxy: nil)
      raise "no API key provided" if keys.empty?

      url = "https://api.search.brave.com/res/v1/web/search?q=#{CGI.escape(query)}&count=#{count}"
      freshness = RangeMaps.brave(range_code)
      url += "&freshness=#{CGI.escape(freshness)}" unless freshness.empty?

      last_err = nil
      keys.each do |key|
        response, body = WebHttp.plain_get(url, headers: { "Accept" => "application/json", "X-Subscription-Token" => key },
                                                timeout: SEARCH_TIMEOUT, proxy: proxy)
        if response.code.to_i != 200
          last_err = "API error (status #{response.code}): #{body}"
          next if [401, 403, 429].include?(response.code.to_i) || response.code.to_i >= 500

          raise last_err
        end
        results = JSON.parse(body).dig("web", "results").to_a
        if results.empty?
          warn "web_search: Brave API returned empty results (query: #{query})"
          return "No results for: #{query}"
        end
        items = results.first(count).map { |r| { title: r["title"], url: r["url"], snippet: r["description"] } }
        return format_items(query, items)
      rescue WebHttp::Error => e
        last_err = e.message
      end
      raise "all api keys failed, last error: #{last_err}"
    end

    def tavily(query, count, range_code, keys:, base_url: nil, proxy: nil)
      raise "no API key provided" if keys.empty?

      url = base_url.to_s.empty? ? "https://api.tavily.com/search" : base_url
      last_err = nil
      keys.each do |key|
        payload = { "api_key" => key, "query" => query, "search_depth" => "advanced",
                    "include_answer" => false, "include_images" => false,
                    "include_raw_content" => false, "max_results" => count }
        time_range = RangeMaps.tavily(range_code)
        payload["time_range"] = time_range unless time_range.empty?
        response, body = WebHttp.plain_post(url, body: JSON.generate(payload),
                                                 headers: { "Content-Type" => "application/json", "User-Agent" => USER_AGENT },
                                                 timeout: SEARCH_TIMEOUT, proxy: proxy)
        if response.code.to_i != 200
          last_err = "tavily api error (status #{response.code}): #{body}"
          next if [401, 403, 429].include?(response.code.to_i) || response.code.to_i >= 500

          raise last_err
        end
        results = JSON.parse(body)["results"].to_a
        return "No results for: #{query}" if results.empty?

        items = results.first(count).map { |r| { title: r["title"], url: r["url"], snippet: r["content"] } }
        return format_items(query, items, via: "Tavily")
      rescue WebHttp::Error => e
        last_err = e.message
      end
      raise "all api keys failed, last error: #{last_err}"
    end

    def kagi(query, count, range_code, keys:, base_url: nil, proxy: nil)
      raise "no API key provided" if keys.empty?

      server = kagi_server_url(base_url)
      payload = { "query" => query, "workflow" => "search", "format" => "json",
                  "safe_search" => true, "limit" => count }
      if (lens = RangeMaps.kagi_lens(range_code))
        payload["lens"] = lens
      end

      last_err = nil
      keys.each do |key|
        response, body = WebHttp.plain_post("#{server}/search", body: JSON.generate(payload),
                                                 headers: { "Content-Type" => "application/json", "Accept" => "application/json",
                                                            "Authorization" => "Bot #{key}", "User-Agent" => HONEST_UA },
                                                 timeout: SEARCH_TIMEOUT, proxy: proxy, max_bytes: 2 << 20)
        code = response.code.to_i
        if code != 200
          last_err = kagi_status_error(code)
          next if [401, 403, 429].include?(code) || code >= 500

          raise last_err
        end
        items = parse_kagi_results(body, count)
        return "No results for: #{query}" if items.empty?

        return format_items(query, items, via: "Kagi")
      rescue WebHttp::Error => e
        last_err = e.message
      end
      raise "all api keys failed, last error: #{last_err}"
    end

    def kagi_server_url(base_url)
      base = base_url.to_s.strip
      return "https://kagi.com/api/v1" if base.empty?

      uri = URI.parse(base)
      if uri.scheme.to_s.empty? || uri.host.to_s.empty?
        return base.sub(%r{/+\z}, "")
      end
      uri.query = nil
      uri.fragment = nil
      uri.path = uri.path.sub(%r{/+\z}, "").sub(%r{/search\z}, "")
      uri.path = "/" if uri.path.empty?
      uri.to_s.sub(%r{/+\z}, "")
    rescue URI::InvalidURIError
      base.sub(%r{/+\z}, "")
    end

    def kagi_status_error(code)
      case code
      when 401 then "Kagi Search API authentication failed (status 401)"
      when 403 then "Kagi Search API request forbidden (status 403)"
      when 429 then "Kagi Search API rate limited (status 429)"
      else
          code >= 500 ? "Kagi Search API server error (status #{code})" : "Kagi Search API error (status #{code})"
      end
    end

    # Modern envelope {"data": {"search": [...]}} and legacy {"data": [...]}
    # (legacy keeps only t==0 entries).
    def parse_kagi_results(body, count)
      data = JSON.parse(body)["data"]
      return [] if data.nil?

      raw =
        if data.is_a?(Hash)
          data["search"].to_a
        elsif data.is_a?(Array)
          data.select { |item| item["t"].to_i.zero? }
        else
          raise "failed to parse response: unexpected data shape"
        end
      raw.first(count).filter_map do |item|
        url = item["url"].to_s.strip
        next if url.empty?

        published = item["published"].to_s.strip
        published = item["time"].to_s.strip if published.empty?
        { title: clean_text(item["title"].to_s), url: url,
          snippet: clean_text(item["snippet"].to_s), published: published }
      end
    rescue JSON::ParserError => e
      raise "failed to parse response: #{e.message}"
    end

    def sogou(query, count, range_code, proxy: nil)
      results = []
      seen = {}
      max_pages = [3, (count + 1) / 2 + 1].min

      (1..max_pages).each do |page|
        break if results.size >= count

        params = URI.encode_www_form("keyword" => RangeMaps.sogou_hint(query, range_code), "v" => "5", "p" => page.to_s)
        response, body = WebHttp.plain_get("https://wap.sogou.com/web/searchList.jsp?#{params}",
                                           headers: { "User-Agent" => SOGOU_USER_AGENT },
                                           timeout: SEARCH_TIMEOUT, proxy: proxy, max_bytes: 1 << 20)
        raise "Sogou returned status #{response.code}" if response.code.to_i != 200
        break if body.length < 200

        body.scan(RE_SOGOU_TITLE) do |href, title_html|
          title = clean_text(title_html)
          link = href[RE_SOGOU_REAL_URL, 1]
          link = link ? CGI.unescape(link) : ""
          next if title.empty? || link.empty? || seen[link]

          seen[link] = true
          after = body[body.index(Regexp.last_match(0))..].to_s[0, 2000].to_s
          snippet = (m = after.match(RE_SOGOU_SNIPPET)) ? clean_text(m[1]) : ""
          results << { title: title, url: link, snippet: snippet }
          break if results.size >= count
        end
      end
      format_items(query, results, via: "Sogou")
    end

    def duckduckgo(query, count, range_code, proxy: nil)
      url = "https://html.duckduckgo.com/html/?q=#{CGI.escape(query)}"
      date_filter = RangeMaps.duckduckgo(range_code)
      url += "&df=#{CGI.escape(date_filter)}" unless date_filter.empty?

      _response, body = WebHttp.plain_get(url, headers: { "User-Agent" => USER_AGENT },
                                               timeout: SEARCH_TIMEOUT, proxy: proxy)
      matches = body.scan(RE_DDG_LINK).first(count + 5)
      return "No results found or extraction failed. Query: #{query}" if matches.empty?

      snippets = body.scan(RE_DDG_SNIPPET).first(count + 5)
      lines = ["Results for: #{query} (via DuckDuckGo)"]
      matches.first(count).each_with_index do |(href, title_html), i|
        url_str = href
        if url_str.include?("uddg=")
          decoded = CGI.unescape(url_str)
          url_str = decoded.split("uddg=", 2)[1] if decoded.include?("uddg=")
        end
        lines << "#{i + 1}. #{clean_text(title_html)}\n   #{url_str}"
        snippet = i < snippets.size ? clean_text(snippets[i][0]) : ""
        lines << "   #{snippet}" unless snippet.empty?
      end
      lines.join("\n")
    end

    def gemini(query, count, _range_code, api_key:, model: nil, proxy: nil)
      raise "no API key provided" if api_key.to_s.strip.empty?

      model = model.to_s.strip
      model = "gemini-2.5-flash" if model.empty?
      payload = { "contents" => [{ "parts" => [{ "text" => query }] }],
                  "tools" => [{ "google_search" => {} }] }
      url = "https://generativelanguage.googleapis.com/v1beta/models/#{CGI.escape(model)}:generateContent"
      response, body = WebHttp.plain_post(url, body: JSON.generate(payload),
                                               headers: { "Content-Type" => "application/json",
                                                          "X-Goog-Api-Key" => api_key, "User-Agent" => HONEST_UA },
                                               timeout: SEARCH_TIMEOUT, proxy: proxy, max_bytes: 2 << 20)
      raise "gemini search api error (status #{response.code}): #{body}" if response.code.to_i != 200

      candidates = JSON.parse(body)["candidates"].to_a
      return "No results for: #{query}" if candidates.empty?

      candidate = candidates.first
      lines = ["Results for: #{query} (via Gemini Google Search)"]
      candidate.dig("content", "parts").to_a.each do |part|
        text = part["text"].to_s.strip
        lines << text unless text.empty?
      end
      citations = 0
      candidate.dig("groundingMetadata", "groundingChunks").to_a.each do |chunk|
        uri = chunk.dig("web", "uri").to_s.strip
        next if uri.empty?

        citations += 1
        title = chunk.dig("web", "title").to_s.strip
        lines << "#{citations}. #{title.empty? ? uri : title}\n   #{uri}"
        break if citations >= count
      end
      lines.join("\n")
    end

    def perplexity(query, count, range_code, keys:, proxy: nil)
      raise "no API key provided" if keys.empty?

      last_err = nil
      keys.each do |key|
        payload = {
          "model" => "sonar",
          "messages" => [
            { "role" => "system", "content" => "You are a search assistant. Provide concise search results with titles, URLs, and brief descriptions in the following format:\n1. Title\n   URL\n   Description\n\nDo not add extra commentary." },
            { "role" => "user", "content" => "Search for: #{query}. Provide up to #{count} relevant results." },
          ],
          "max_tokens" => 1000,
        }
        recency = RangeMaps.perplexity(range_code)
        payload["search_recency_filter"] = recency unless recency.empty?
        response, body = WebHttp.plain_post("https://api.perplexity.ai/chat/completions",
                                                 body: JSON.generate(payload),
                                                 headers: { "Content-Type" => "application/json",
                                                            "Authorization" => "Bearer #{key}", "User-Agent" => USER_AGENT },
                                                 timeout: SLOW_TIMEOUT, proxy: proxy)
        if response.code.to_i != 200
          last_err = "Perplexity API error: #{body}"
          next if [401, 403, 429].include?(response.code.to_i) || response.code.to_i >= 500

          raise last_err
        end
        choices = JSON.parse(body)["choices"].to_a
        return "No results for: #{query}" if choices.empty?

        return "Results for: #{query} (via Perplexity)\n#{choices.first.dig("message", "content")}"
      rescue WebHttp::Error => e
        last_err = e.message
      end
      raise "all api keys failed, last error: #{last_err}"
    end

    def searxng(query, count, range_code, base_url:, proxy: nil)
      raise "no SearXNG URL provided" if base_url.to_s.empty?

      url = "#{base_url.sub(%r{/+\z}, "")}/search?q=#{CGI.escape(query)}&format=json&categories=general"
      time_range = RangeMaps.searxng(range_code)
      url += "&time_range=#{CGI.escape(time_range)}" unless time_range.empty?
      response, body = WebHttp.plain_get(url, timeout: SEARCH_TIMEOUT, proxy: proxy)
      raise "SearXNG returned status #{response.code}" if response.code.to_i != 200

      results = JSON.parse(body)["results"].to_a
      return "No results for: #{query}" if results.empty?

      items = results.first(count).map { |r| { title: r["title"], url: r["url"], snippet: r["content"] } }
      format_items(query, items, via: "SearXNG")
    end

    def glm(query, count, range_code, api_key:, base_url: nil, search_engine: nil, proxy: nil)
      raise "no API key provided" if api_key.to_s.empty?

      url = base_url.to_s.empty? ? "https://open.bigmodel.cn/api/paas/v4/web_search" : base_url
      engine = search_engine.to_s.empty? ? "search_std" : search_engine
      payload = { "search_query" => query, "search_engine" => engine, "search_intent" => false,
                  "count" => count, "content_size" => "medium",
                  "search_recency_filter" => RangeMaps.glm(range_code) }
      response, body = WebHttp.plain_post(url, body: JSON.generate(payload),
                                               headers: { "Content-Type" => "application/json",
                                                          "Authorization" => "Bearer #{api_key}" },
                                               timeout: SEARCH_TIMEOUT, proxy: proxy, max_bytes: 1 << 20)
      raise "GLM Search API error (status #{response.code}): #{body}" if response.code.to_i != 200

      results = JSON.parse(body)["search_result"].to_a
      return "No results for: #{query}" if results.empty?

      items = results.first(count).map { |r| { title: r["title"], url: r["link"], snippet: r["content"] } }
      format_items(query, items, via: "GLM Search")
    end

    def baidu(query, count, range_code, api_key:, base_url: nil, proxy: nil)
      raise "no API key provided" if api_key.to_s.empty?

      url = base_url.to_s.empty? ? "https://qianfan.baidubce.com/v2/ai_search/web_search" : base_url
      payload = { "messages" => [{ "role" => "user", "content" => query }],
                  "search_source" => "baidu_search_v2",
                  "resource_type_filter" => [{ "type" => "web", "top_k" => count }] }
      recency = RangeMaps.baidu(range_code)
      payload["search_recency_filter"] = recency unless recency.empty?
      response, body = WebHttp.plain_post(url, body: JSON.generate(payload),
                                               headers: { "Content-Type" => "application/json",
                                                          "Authorization" => "Bearer #{api_key}" },
                                               timeout: SLOW_TIMEOUT, proxy: proxy, max_bytes: 1 << 20)
      raise "baidu search API error #{response.code}: #{body}" if response.code.to_i != 200

      results = JSON.parse(body)["references"].to_a
      return "No results for: #{query}" if results.empty?

      items = results.first(count).map { |r| { title: r["title"], url: r["url"], snippet: r["content"] } }
      format_items(query, items, via: "Baidu Search")
    end
  end

  # --- tool ----------------------------------------------------------------------

  # options: the tools.web config section (string-keyed hash).
  def initialize(options: {}, proxy: nil)
    @options = options || {}
    @proxy = proxy.to_s.empty? ? nil : proxy
  end

  def name = "web_search"

  def execute(**args)
    query = args[:query]
    return "query is required" unless query.is_a?(String) && !query.strip.empty?

    query = query.strip

    provider_name, max_results = resolve_provider(query)
    return "search provider is not configured" if provider_name.nil?

    count = max_results
    raw_count = args[:count]
    if raw_count.is_a?(String)
      return "invalid integer format for count parameter: invalid syntax" unless raw_count.match?(/\A[+-]?\d+\z/)

      raw_count = raw_count.to_i
    end
    if raw_count.is_a?(Numeric)
      return "count must be an integer, got float #{raw_count}" if raw_count.is_a?(Float) && raw_count != raw_count.truncate

      requested = raw_count.to_i
      count = [requested, max_results].min if requested.positive? && requested <= 10
    end

    range_code = ""
    if args.key?(:range)
      return "range must be a string" unless args[:range].is_a?(String)

      begin
        range_code = RangeMaps.normalize(args[:range])
      rescue ArgumentError => e
        return e.message
      end
    end

    run_provider(provider_name, query, count, range_code)
  rescue ArgumentError, WebHttp::Error => e
    "search failed: #{e.message}"
  rescue StandardError => e
    warn("web_search crashed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    "search failed: #{e.message}"
  end

  # --- resolution (all class-level so main.rb can decide whether to register) ---

  def self.provider_ready?(options, name)
    cfg = (options || {})[name]
    case name
    when "sogou" then cfg.nil? || cfg.fetch("enabled", true)
    when "duckduckgo" then cfg && cfg.fetch("enabled", false)
    when "gemini" then cfg && cfg.fetch("enabled", false) && !cfg["api_key"].to_s.strip.empty?
    when "brave", "tavily", "kagi", "perplexity"
      cfg && cfg.fetch("enabled", false) && !Array(cfg["api_keys"]).empty?
    when "searxng" then cfg && cfg.fetch("enabled", false) && !cfg["base_url"].to_s.strip.empty?
    when "glm_search", "baidu_search"
      cfg && cfg.fetch("enabled", false) && !cfg["api_key"].to_s.strip.empty?
    else false
    end ? true : false
  end

  # The upstream heuristic: Han script → sogou, Latin letters → duckduckgo.
  def self.prefers_duckduckgo?(query)
    trimmed = query.strip
    return false if trimmed.empty?
    return false if trimmed.match?(/\p{Han}/)

    trimmed.match?(/\p{Latin}/)
  end

  def self.resolve_provider_name(options, query)
    configured = (options || {})["provider"].to_s.strip.downcase
    configured = "auto" if !configured.empty? && configured != "auto" && !KNOWN_PROVIDERS.include?(configured)

    return configured if !configured.empty? && configured != "auto" && provider_ready?(options, configured)

    AUTO_PRIMARY.each { |name| return name if provider_ready?(options, name) }

    sogou = provider_ready?(options, "sogou")
    duck = provider_ready?(options, "duckduckgo")
    if sogou && duck
      return prefers_duckduckgo?(query) ? "duckduckgo" : "sogou"
    end
    return "sogou" if sogou
    return "duckduckgo" if duck

    AUTO_FALLBACK.each { |name| return name if provider_ready?(options, name) }
    nil
  end

  def self.registerable?(options)
    !resolve_provider_name(options, "").nil?
  end

  private

  def max_results_for(name)
    cfg = (@options[name] || {})
    configured = cfg["max_results"].to_i
    configured.positive? ? [configured, 10].min : 10
  end

  def resolve_provider(query)
    name = self.class.resolve_provider_name(@options, query)
    name.nil? ? [nil, 0] : [name, max_results_for(name)]
  end

  def run_provider(name, query, count, range_code)
    cfg = @options[name] || {}
    proxy = @proxy || cfg["proxy"]
    case name
    when "brave"
      Providers.brave(query, count, range_code, keys: KeyPool.new(cfg["api_keys"]), proxy: proxy)
    when "tavily"
      Providers.tavily(query, count, range_code, keys: KeyPool.new(cfg["api_keys"]),
                       base_url: cfg["base_url"], proxy: proxy)
    when "kagi"
      Providers.kagi(query, count, range_code, keys: KeyPool.new(cfg["api_keys"]),
                     base_url: cfg["base_url"], proxy: proxy)
    when "perplexity"
      Providers.perplexity(query, count, range_code, keys: KeyPool.new(cfg["api_keys"]), proxy: proxy)
    when "sogou" then Providers.sogou(query, count, range_code, proxy: proxy)
    when "duckduckgo" then Providers.duckduckgo(query, count, range_code, proxy: proxy)
    when "gemini"
      Providers.gemini(query, count, range_code, api_key: cfg["api_key"], model: cfg["model"], proxy: proxy)
    when "searxng"
      Providers.searxng(query, count, range_code, base_url: cfg["base_url"], proxy: proxy)
    when "glm_search"
      Providers.glm(query, count, range_code, api_key: cfg["api_key"],
                    base_url: cfg["base_url"], search_engine: cfg["search_engine"], proxy: proxy)
    when "baidu_search"
      Providers.baidu(query, count, range_code, api_key: cfg["api_key"], base_url: cfg["base_url"], proxy: proxy)
    else
      raise "unknown web search provider #{name.inspect}"
    end
  end
end
