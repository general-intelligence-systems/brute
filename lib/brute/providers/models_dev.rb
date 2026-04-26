# frozen_string_literal: true

require "net/http"
require "json"

module Brute
  module Providers
    # Fetches and caches model metadata from the models.dev catalog.
    #
    # Quacks like a provider.models interface so that the REPL's model
    # picker can call:
    #
    #   provider.models.all.select(&:chat?)
    #
    # Models are fetched from https://models.dev/api.json and cached
    # in-memory for the lifetime of the process (with a TTL).
    #
    class ModelsDev
      CATALOG_URL = "https://models.dev/api.json"
      CACHE_TTL = 3600 # 1 hour

      ModelEntry = Struct.new(:id, :name, :chat?, :cost, :limit, :reasoning, :tool_call, keyword_init: true)

      # @param provider [Brute::Providers::*] the provider instance
      # @param provider_id [String] the provider key in models.dev (e.g., "opencode", "opencode-go")
      def initialize(provider:, provider_id: "opencode")
        @provider = provider
        @provider_id = provider_id
      end

      # Returns all models for this provider from the models.dev catalog.
      # @return [Array<ModelEntry>]
      def all
        entries = fetch_provider_models
        entries.map do |id, model|
          ModelEntry.new(
            id: id,
            name: model["name"] || id,
            chat?: true,
            cost: model["cost"],
            limit: model["limit"],
            reasoning: model["reasoning"] || false,
            tool_call: model["tool_call"] || false
          )
        end.sort_by(&:id)
      end

      private

      def fetch_provider_models
        catalog = self.class.fetch_catalog
        provider_data = catalog[@provider_id]
        return {} unless provider_data

        provider_data["models"] || {}
      end

      class << self
        # Fetch the models.dev catalog, with in-memory caching.
        # Thread-safe via a simple mutex.
        def fetch_catalog
          @mutex ||= Mutex.new
          @mutex.synchronize do
            if @catalog && @fetched_at && (Time.now - @fetched_at < CACHE_TTL)
              return @catalog
            end

            @catalog = download_catalog
            @fetched_at = Time.now
            @catalog
          end
        end

        # Force a cache refresh on next access.
        def invalidate_cache!
          @mutex&.synchronize do
            @catalog = nil
            @fetched_at = nil
          end
        end

        private

        def download_catalog
          uri = URI.parse(CATALOG_URL)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 10
          http.read_timeout = 30

          request = Net::HTTP::Get.new(uri.request_uri)
          request["User-Agent"] = "brute/#{Brute::VERSION}"
          request["Accept"] = "application/json"

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            raise "Failed to fetch models.dev catalog: HTTP #{response.code}"
          end

          JSON.parse(response.body)
        rescue => e
          # Return empty catalog on failure so the provider still works
          # with default_model, just without a model list.
          warn "[brute] Warning: Could not fetch models.dev catalog: #{e.message}"
          {}
        end
      end
    end
  end
end
