# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"
require "net/http"

# Grafana dashboarding tools, ported from inference-gateway/grafana-agent
# (tools/*.go + internal/promql/builder.go). Tool names, descriptions, and
# parameter descriptions are copied verbatim; the PromQL suggestion
# generators mirror the upstream builder per metric type.
#
# Configuration:
#   PROMETHEUS_URL          default Prometheus server (the prompt tells the
#                           LLM to use it for prometheus_url parameters)
#   GRAFANA_URL             default Grafana server for deployments
#   GRAFANA_API_KEY         Grafana service account token (Bearer auth)
#   GRAFANA_DEPLOY_ENABLED  must be "true" before deploy_dashboard will run
module GrafanaAgent
  # Thin Prometheus HTTP API client (the parts builder.go uses).
  class Prometheus
    def initialize(base_url)
      @base_url = base_url.chomp("/")
    end

    def metric_names
      get("/api/v1/label/__name__/values").fetch("data", [])
    end

    # { "metric_name" => { "type" => ..., "help" => ... } }
    def metadata(metric: nil)
      params = metric ? { metric: metric } : {}
      data = get("/api/v1/metadata", params).fetch("data", {})
      data.transform_values { |entries| entries.first || {} }
    end

    def labels_for(metric)
      get("/api/v1/labels", "match[]": metric).fetch("data", [])
    end

    # Returns nil when the query is valid, or the error string when not.
    def query_error(query)
      response = get("/api/v1/query", query: query, allow_failure: true)
      return nil if response["status"] == "success"

      "#{response["error"]} (#{response["errorType"]})"
    end

    private

      def get(path, params = {})
        allow_failure = params.delete(:allow_failure)
        uri = URI("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?

        response = Net::HTTP.get_response(uri)
        body = JSON.parse(response.body)
        unless response.is_a?(Net::HTTPSuccess) || allow_failure
          raise "Prometheus API request failed: #{response.code} #{response.message} (#{path})"
        end

        body
      end
  end

  # PromQL query suggestions per metric type — ports generateQueries and
  # friends from internal/promql/builder.go, including the verbatim
  # descriptions and visualization hints.
  module PromQL
    module_function

    def suggestions(name, type, labels = [])
      case type
      when "counter"   then counter_queries(name, labels)
      when "gauge"     then gauge_queries(name, labels)
      when "histogram" then histogram_queries(name)
      when "summary"   then summary_queries(name)
      else                  default_queries(name, labels)
      end
    end

    def counter_queries(name, labels)
      suggestions = [
        { query: "rate(#{name}[5m])", description: "Rate per second over 5 minutes", visualization_type: "timeseries", y_axis_label: "per second" },
        { query: "increase(#{name}[1h])", description: "Total increase over 1 hour", visualization_type: "timeseries", y_axis_label: "total" },
      ]
      visible_labels(labels).each do |label|
        suggestions << { query: "sum by (#{label}) (rate(#{name}[5m]))", description: "Rate per second grouped by #{label}", visualization_type: "timeseries", y_axis_label: "per second" }
      end
      suggestions
    end

    def gauge_queries(name, labels)
      suggestions = [
        { query: name, description: "Current value", visualization_type: "timeseries", y_axis_label: "value" },
        { query: "avg_over_time(#{name}[1h])", description: "Average over 1 hour", visualization_type: "timeseries", y_axis_label: "avg value" },
      ]
      if labels.any?
        suggestions << { query: "avg(#{name})", description: "Average across all instances", visualization_type: "stat", y_axis_label: "avg value" }
        suggestions << { query: "max(#{name})", description: "Maximum value", visualization_type: "stat", y_axis_label: "max value" }
        suggestions << { query: "min(#{name})", description: "Minimum value", visualization_type: "stat", y_axis_label: "min value" }
        visible_labels(labels).each do |label|
          suggestions << { query: "avg by (#{label}) (#{name})", description: "Average grouped by #{label}", visualization_type: "timeseries", y_axis_label: "avg value" }
        end
      end
      suggestions
    end

    def histogram_queries(name)
      base = name.delete_suffix("_bucket").delete_suffix("_count").delete_suffix("_sum")
      [
        { query: "histogram_quantile(0.50, rate(#{base}_bucket[5m]))", description: "50th percentile (median) over 5 minutes", visualization_type: "timeseries", y_axis_label: "duration" },
        { query: "histogram_quantile(0.95, rate(#{base}_bucket[5m]))", description: "95th percentile over 5 minutes", visualization_type: "timeseries", y_axis_label: "duration" },
        { query: "histogram_quantile(0.99, rate(#{base}_bucket[5m]))", description: "99th percentile over 5 minutes", visualization_type: "timeseries", y_axis_label: "duration" },
        { query: "rate(#{base}_count[5m])", description: "Request rate (requests per second)", visualization_type: "timeseries", y_axis_label: "requests/sec" },
        { query: "rate(#{base}_sum[5m]) / rate(#{base}_count[5m])", description: "Average duration", visualization_type: "timeseries", y_axis_label: "avg duration" },
      ]
    end

    def summary_queries(name)
      base = name.delete_suffix("_count").delete_suffix("_sum")
      suggestions = [
        { query: "rate(#{base}_count[5m])", description: "Request rate (requests per second)", visualization_type: "timeseries", y_axis_label: "requests/sec" },
        { query: "rate(#{base}_sum[5m]) / rate(#{base}_count[5m])", description: "Average value", visualization_type: "timeseries", y_axis_label: "avg value" },
      ]
      if name.include?("_count") || name.include?("_sum")
        %w[0.5 0.9 0.95 0.99].each do |quantile|
          suggestions << { query: "#{base}{quantile=\"#{quantile}\"}", description: "#{quantile} quantile", visualization_type: "timeseries", y_axis_label: "value" }
        end
      end
      suggestions
    end

    def default_queries(name, labels)
      if name.end_with?("_total") || name.include?("_count") || name.include?("requests") || name.include?("errors")
        return counter_queries(name, labels)
      end

      [
        { query: name, description: "Raw metric value", visualization_type: "timeseries", y_axis_label: "value" },
        { query: "rate(#{name}[5m])", description: "Rate of change over 5 minutes", visualization_type: "timeseries", y_axis_label: "per second" },
      ]
    end

    def visible_labels(labels)
      labels.reject { |label| label == "__name__" || label.start_with?("__") }
    end
  end

  class DiscoverMetrics < RubyLLM::Tool
    description "Discovers available metrics from a Prometheus endpoint with optional filtering"

    params({
      type: "object",
      properties: {
        prometheus_url: { type: "string", description: "Prometheus server URL to discover metrics from" },
        name_pattern:   { type: "string", description: "Optional regex pattern to filter metrics by name" },
        metric_type:    { type: "string", description: "Optional metric type filter (counter, gauge, histogram, summary)", enum: %w[counter gauge histogram summary] },
      },
      required: %w[prometheus_url],
    })

    def name = "discover_metrics"

    def execute(prometheus_url:, name_pattern: nil, metric_type: nil)
      prometheus = Prometheus.new(prometheus_url)
      metadata = prometheus.metadata

      metrics = prometheus.metric_names.map do |metric_name|
        info = metadata[metric_name] || {}
        { name: metric_name, type: info["type"], help: info["help"] }.compact
      end
      metrics.select! { |m| m[:name] =~ Regexp.new(name_pattern) } if name_pattern
      metrics.select! { |m| m[:type] == metric_type } if metric_type

      JSON.generate(
        prometheus_url: prometheus_url,
        total_metrics:  metrics.size,
        metrics:        metrics,
        filters:        { name_pattern: name_pattern, metric_type: metric_type }.compact,
      )
    end
  end

  class GeneratePromqlQueries < RubyLLM::Tool
    description "Generates PromQL query suggestions for given metric names by querying Prometheus metadata"

    params({
      type: "object",
      properties: {
        prometheus_url: { type: "string", description: "Prometheus server URL for querying metric metadata" },
        metric_names:   { type: "array", items: { type: "string" }, description: "Array of metric names to generate queries for" },
      },
      required: %w[prometheus_url metric_names],
    })

    def name = "generate_promql_queries"

    def execute(prometheus_url:, metric_names:)
      raise "metric_names cannot be empty" if Array(metric_names).empty?

      prometheus = Prometheus.new(prometheus_url)

      results = Array(metric_names).map do |metric_name|
        info   = prometheus.metadata(metric: metric_name)[metric_name] || {}
        labels = prometheus.labels_for(metric_name)
        {
          metric_name: metric_name,
          metric_type: info["type"],
          metric_help: info["help"],
          labels:      labels,
          suggestions: PromQL.suggestions(metric_name, info["type"], labels),
        }.compact
      rescue => e
        { metric_name: metric_name, error: e.message }
      end

      JSON.generate(prometheus_url: prometheus_url, results: results)
    end
  end

  class ValidatePromqlQuery < RubyLLM::Tool
    description "Validates a PromQL query against a Prometheus server"

    param :prometheus_url, type: "string", desc: "Prometheus server URL to validate against", required: true
    param :query, type: "string", desc: "PromQL query to validate", required: true

    def name = "validate_promql_query"

    def execute(prometheus_url:, query:)
      error = Prometheus.new(prometheus_url).query_error(query)
      JSON.generate({
        prometheus_url: prometheus_url,
        query:          query,
        valid:          error.nil?,
        error:          error,
      }.compact)
    end
  end

  class CreateDashboard < RubyLLM::Tool
    description "Creates a Grafana dashboard with specified panels, queries, and configurations"

    params({
      type: "object",
      properties: {
        dashboard_title:  { type: "string", description: "The title of the Grafana dashboard" },
        description:      { type: "string", description: "Description of what the dashboard monitors or displays" },
        panels:           { type: "array", items: { type: "object" }, description: "Array of panel configurations (title, type, queries, etc.)" },
        tags:             { type: "array", items: { type: "string" }, description: "Tags to categorize the dashboard" },
        time_range:       { type: "object", properties: { from: { type: "string" }, to: { type: "string" } }, description: "Default time range for the dashboard (from, to)" },
        refresh_interval: { type: "string", description: "Auto-refresh interval (e.g., \"5s\", \"1m\", \"5m\")" },
        variables:        { type: "array", items: { type: "object" }, description: "Dashboard template variables for dynamic queries" },
        deploy:           { type: "boolean", description: "Whether to deploy the dashboard to Grafana (requires grafana_url and GRAFANA_DEPLOY_ENABLED=true)" },
        grafana_url:      { type: "string", description: "Grafana server URL (overrides default configuration if provided)" },
      },
      required: %w[dashboard_title panels],
    })

    def name = "create_dashboard"

    def execute(dashboard_title:, panels:, description: nil, tags: nil,
                time_range: nil, refresh_interval: nil, variables: nil,
                deploy: false, grafana_url: nil)
      time_range = (time_range || {}).transform_keys(&:to_s)

      dashboard = {
        "title"       => dashboard_title,
        "description" => description,
        "tags"        => tags,
        "time"        => { "from" => time_range["from"] || "now-6h", "to" => time_range["to"] || "now" },
        "refresh"     => refresh_interval,
        "templating"  => variables ? { "list" => variables } : nil,
        "panels"      => positioned_panels(panels),
        "schemaVersion" => 39,
      }.compact

      if deploy
        deployed = GrafanaAgent.deploy(dashboard, grafana_url: grafana_url)
        JSON.generate(dashboard: dashboard, deployed: true, response: deployed)
      else
        JSON.generate(dashboard: dashboard, deployed: false)
      end
    end

    private

      # Assign ids and a two-column grid layout to panels missing gridPos.
      def positioned_panels(panels)
        panels.each_with_index.map do |panel, index|
          panel = panel.transform_keys(&:to_s)
          panel["id"]      ||= index + 1
          panel["gridPos"] ||= { "h" => 8, "w" => 12, "x" => (index % 2) * 12, "y" => (index / 2) * 8 }
          panel
        end
      end
  end

  class DeployDashboard < RubyLLM::Tool
    description "Deploys a dashboard JSON to Grafana (Cloud or self-hosted)"

    params({
      type: "object",
      properties: {
        dashboard_json: { type: "object", description: "The complete dashboard JSON object to deploy" },
        grafana_url:    { type: "string", description: "Grafana server URL (user provides in prompt or uses config default)" },
        folder_uid:     { type: "string", description: "Optional folder UID where the dashboard should be deployed" },
        message:        { type: "string", description: "Optional commit message describing the dashboard changes" },
        overwrite:      { type: "boolean", description: "Whether to overwrite an existing dashboard with the same UID (default true)" },
      },
      required: %w[dashboard_json],
    })

    def name = "deploy_dashboard"

    def execute(dashboard_json:, grafana_url: nil, folder_uid: nil, message: nil, overwrite: true)
      response = GrafanaAgent.deploy(
        dashboard_json,
        grafana_url: grafana_url,
        folder_uid:  folder_uid,
        message:     message,
        overwrite:   overwrite,
      )
      JSON.generate(response)
    end
  end

  # POST a dashboard to the Grafana API. Gated on GRAFANA_DEPLOY_ENABLED,
  # same as upstream.
  def self.deploy(dashboard, grafana_url: nil, folder_uid: nil, message: nil, overwrite: true)
    unless ENV["GRAFANA_DEPLOY_ENABLED"] == "true"
      raise "grafana deployment is disabled - set GRAFANA_DEPLOY_ENABLED=true to enable dashboard deployments"
    end

    grafana_url ||= ENV["GRAFANA_URL"]
    if grafana_url.nil? || grafana_url.empty?
      raise "grafana_url must be provided either as a parameter or in configuration (GRAFANA_URL)"
    end

    uri = URI("#{grafana_url.chomp("/")}/api/dashboards/db")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{ENV["GRAFANA_API_KEY"]}" if ENV["GRAFANA_API_KEY"]
    request.body = JSON.generate({
      dashboard: dashboard,
      folderUid: folder_uid,
      message:   message,
      overwrite: overwrite,
    }.compact)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
    unless response.is_a?(Net::HTTPSuccess)
      raise "Grafana API request failed: #{response.code} #{response.message} — #{response.body}"
    end

    JSON.parse(response.body)
  end

  TOOLS = [
    DiscoverMetrics,
    GeneratePromqlQueries,
    ValidatePromqlQuery,
    CreateDashboard,
    DeployDashboard,
  ].freeze
end
