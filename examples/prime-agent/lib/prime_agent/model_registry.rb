# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module PrimeAgent
  # ModelRegistry — the authenticated model catalog + bounded fuzzy search
  # behind `KernelAgent.find_models` (K2). The search scoring is ported
  # verbatim from prime-agent's findRlmModelMatches
  # (core/rlm-runtime.ts:118-152): exact < prefix < substring across
  # "provider/id", id, and name, with selector tie-break and a limit clamped
  # to 20. The catalog is OpenRouter's /models, keyed by OPENROUTER_API_KEY;
  # it is never exposed to the prompt — only bounded matches return.
  #
  # Pure stdlib — loadable without brute or any gem (used in-kernel).
  module ModelRegistry
    DEFAULT_LIMIT = 8  # DEFAULT_RLM_MODEL_SEARCH_LIMIT
    MAX_LIMIT = 20     # MAX_RLM_MODEL_SEARCH_LIMIT
    CATALOG_URL = "https://openrouter.ai/api/v1/models"
    CACHE_TTL_SECONDS = 60

    module_function

    # Catalog URL override (also the integration seam for a canned catalog).
    def catalog_url
      ENV["BRUTE_MODELS_URL"] || CATALOG_URL
    end

    # The kernel-facing search: bounded matches as upstream's RLMModel shape
    # ({provider, id, name, selector}).
    def find_models(query = "", limit: DEFAULT_LIMIT, api_key: ENV["OPENROUTER_API_KEY"], fetcher: nil)
      raise TypeError, "query must be a String, got #{query.class}" unless query.is_a?(String)
      raise TypeError, "limit must be an Integer, got #{limit.class}" unless limit.is_a?(Integer)

      limit = [0, [limit, MAX_LIMIT].min].max # only the max clamps (upstream slices)
      models = (fetcher || method(:fetch_catalog)).call(api_key)
      find_matches(query, models).first(limit).map do |match|
        {
          "provider" => match[:provider],
          "id" => match[:id],
          "name" => match[:name],
          "selector" => match[:selector],
        }
      end
    end

    # findRlmModelMatches: fields are [selector, id, name]; exact match scores
    # the field index (0-2), prefix scores 3 + index, substring 6 + index;
    # non-matches are dropped; empty query returns the catalog order.
    def find_matches(query, models)
      normalized_query = normalize_text(query.strip)
      models.map do |model|
        selector = "#{model[:provider]}/#{model[:id]}"
        fields = [selector, model[:id], model[:name] || model[:id]]
        normalized = fields.map { |field| normalize_text(field) }
        score = normalized_query.empty? ? 0 : nil
        unless normalized_query.empty?
          exact = normalized.index(normalized_query)
          prefix = normalized.index { |field| field.start_with?(normalized_query) }
          partial = normalized.index { |field| field.include?(normalized_query) }
          score = if exact
                    exact
                  elsif prefix
                    3 + prefix
                  elsif partial
                    6 + partial
                  end
        end
        score && { provider: model[:provider], id: model[:id], name: model[:name] || model[:id],
                   selector: selector, score: score }
      end
        .compact
        .sort_by { |candidate| [candidate[:score], candidate[:selector]] }
    end

    def normalize_text(value)
      value.downcase.gsub(/[^a-z0-9]+/, "")
    end

    # GET the OpenRouter catalog. Entries become {provider, id, name} with
    # provider = the id's first segment (OpenRouter ids are "provider/model").
    def fetch_catalog(api_key)
      @cache = nil if @cache && (Time.now - @cache[:at]) > CACHE_TTL_SECONDS
      return @cache[:models] if @cache

      uri = URI(catalog_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 20
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{api_key}" if api_key && !api_key.empty?
      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise "model catalog fetch failed (#{response.code}): #{response.body}"
      end

      data = JSON.parse(response.body)
      models = (data["data"] || []).filter_map do |entry|
        id = entry["id"].to_s
        next if id.empty?

        provider, _, rest = id.partition("/")
        {
          provider: provider,
          id: rest.empty? ? id : rest,
          name: entry["name"].to_s.empty? ? nil : entry["name"],
        }
      end
      @cache = { at: Time.now, models: models }
      models
    end

    def clear_cache!
      @cache = nil
    end
  end
end

__END__

describe "prime_agent/model_registry" do
  MODELS = [
    { provider: "anthropic", id: "claude-sonnet-4.5", name: "Claude Sonnet 4.5" },
    { provider: "anthropic", id: "claude-haiku-4.5", name: "Claude Haiku 4.5" },
    { provider: "openai", id: "gpt-5", name: "GPT-5" },
    { provider: "openai", id: "gpt-4.1-mini", name: "GPT-4.1 mini" },
    { provider: "google", id: "gemini-2.5-pro", name: "Gemini 2.5 Pro" },
  ].freeze

  def find(query, limit: 8)
    PrimeAgent::ModelRegistry.find_models(query, limit: limit, fetcher: ->(_key) { MODELS })
  end

  it "scores exact < prefix < substring across selector, id, name" do
    find("gpt-5").map { |m| m["selector"] }.first.should == "openai/gpt-5" # exact id
    find("openai/gpt-5").first["id"].should == "gpt-5"                   # exact selector
    find("anthropic").map { |m| m["provider"] }.uniq.should == ["anthropic"] # prefix selector
    find("claude").first["name"].should == "Claude Haiku 4.5"             # prefix id, selector tie-break
    find("sonnet").first["id"].should == "claude-sonnet-4.5"              # substring id
    find("haiku45").first["id"].should == "claude-haiku-4.5"              # normalized
    find("nonexistentmodel").should == []
  end

  it "orders ties by selector and honors the limit clamp" do
    find("claude").map { |m| m["id"] }.should == ["claude-haiku-4.5", "claude-sonnet-4.5"]
    find("", limit: 3).length.should == 3
    find("", limit: 50).length.should == 5 # clamped to MAX_LIMIT=20 then catalog size
  end

  it "validates types" do
    lambda { PrimeAgent::ModelRegistry.find_models(42, fetcher: ->(_k) { [] }) }.should.raise(TypeError)
    lambda { PrimeAgent::ModelRegistry.find_models("x", limit: "8", fetcher: ->(_k) { [] }) }.should.raise(TypeError)
  end
end
