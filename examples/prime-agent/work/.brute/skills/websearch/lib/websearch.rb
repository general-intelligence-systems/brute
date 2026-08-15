# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# Websearch — port of prime-agent
# `packages/coding-agent/skills/websearch/src/websearch/websearch.py`:
# Google search via the Serper API. Kernel-pure (no host bridge); pure stdlib.
# Loaded into IRuby via require "websearch".
#
# Two deliberate behaviors mirror upstream:
#  - the API key is resolved ON EVERY CALL (env first, then auth.json), so a
#    key added after the kernel booted is still picked up;
#  - failures are RETURNED, never raised — the model gets a string it can
#    act on (setup instructions when no key, "Error searching..." otherwise).
module Websearch
  SERPER_URL = "https://google.serper.dev/search"

  # Upstream walks the user through prime-agent's /login UI; this port has no
  # login flow, so the message points at the two key locations resolve_api_key
  # actually reads.
  SETUP_MESSAGE = <<~MSG.freeze
    Web search is not set up yet: no Serper API key is configured.
    Tell the user how to enable it:
      1. Get a free API key at https://serper.dev (sign up, copy the key).
      2. Either set SERPER_API_KEY in the environment, or save the key in
         ~/.prime/agent/auth.json as {"serper": {"type": "api_key", "key": "..."}}
         (the stored value may also be the NAME of an env var holding the key).
    Once the key is saved, web search works automatically.
  MSG

  module_function

  # Run a Google search via Serper and return formatted results.
  #   query:       Google search query.
  #   max_output:  truncate output to this many chars (head+tail with marker).
  #   timeout:     HTTP timeout in seconds (env PRIME_AGENT_WEBSEARCH_TIMEOUT, 45).
  #   num_results: organic results to return (env PRIME_AGENT_WEBSEARCH_NUM_RESULTS, 5).
  def run(query, max_output: 8192, timeout: nil, num_results: nil)
    api_key = resolve_api_key
    return SETUP_MESSAGE if api_key.empty?

    timeout ||= env_int("PRIME_AGENT_WEBSEARCH_TIMEOUT", 45)
    num_results ||= env_int("PRIME_AGENT_WEBSEARCH_NUM_RESULTS", 5)

    result =
      begin
        fetch_serper(query, api_key, timeout: timeout, num_results: num_results)
      rescue StandardError => e
        "Error searching for '#{query}': #{e.message}"
      end
    output = "Results for query \"#{query}\":\n\n#{result}"

    if output.length > max_output
      total = output.length
      marker = "\n... [output truncated, #{total} chars total] ...\n"
      half = [0, (max_output - marker.length) / 2].max
      output = output[0...half] + marker + output[output.length - half..]
      output = output[0...max_output] if output.length > max_output
    end
    output
  end

  def env_int(name, default)
    Integer(ENV.fetch(name))
  rescue ArgumentError, KeyError, TypeError
    default
  end

  # Resolve the agent config dir the same way prime-agent does — the port
  # deliberately shares prime-agent's auth.json so one key works for both.
  def agent_dir
    raw = ENV["PRIME_AGENT_CODING_AGENT_DIR"] || ENV["PI_CODING_AGENT_DIR"] || "~/.prime/agent"
    File.expand_path(raw)
  end

  def resolve_api_key
    env_key = ENV["SERPER_API_KEY"].to_s.strip
    return env_key unless env_key.empty?

    auth = JSON.parse(File.read(File.join(agent_dir, "auth.json")))
    cred = auth["serper"] if auth.is_a?(Hash)
    return resolve_config_value(cred["key"].to_s) if cred.is_a?(Hash) && cred["type"] == "api_key"

    ""
  rescue Errno::ENOENT, JSON::ParserError
    ""
  end

  # Stored keys may be a literal or an env-var name; "!command" refs can't be
  # run safely here, so skip them.
  def resolve_config_value(value)
    value = value.strip
    return "" if value.empty? || value.start_with?("!")

    (ENV[value] || value).strip
  end

  def fetch_serper(query, api_key, timeout:, num_results:)
    uri = URI(SERPER_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = timeout
    http.read_timeout = timeout
    request = Net::HTTP::Post.new(uri)
    request["X-API-KEY"] = api_key
    request["Content-Type"] = "application/json"
    request.body = JSON.dump("q" => query)
    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      raise "Serper search error (#{response.code}): #{response.body}"
    end

    format_serper_results(JSON.parse(response.body), query, num_results: num_results)
  end

  def format_serper_results(data, query, num_results: 5)
    sections = []

    kg = data["knowledgeGraph"]
    if kg
      kg_lines = []
      title = kg["title"].to_s.strip
      kg_lines << "Knowledge Graph: #{title}" unless title.empty?
      description = kg["description"].to_s.strip
      kg_lines << description unless description.empty?
      (kg["attributes"] || {}).each do |key, value|
        text = value.to_s.strip
        kg_lines << "#{key}: #{text}" unless text.empty?
      end
      sections << kg_lines.join("\n") unless kg_lines.empty?
    end

    (data["organic"] || []).first(num_results).each_with_index do |result, i|
      title = result["title"].to_s.strip
      title = "Untitled" if title.empty?
      lines = ["Result #{i}: #{title}"]
      link = result["link"].to_s.strip
      lines << "URL: #{link}" unless link.empty?
      snippet = result["snippet"].to_s.strip
      lines << snippet unless snippet.empty?
      sections << lines.join("\n")
    end

    people_also_ask = data["peopleAlsoAsk"] || []
    questions = []
    people_also_ask.first(3).each do |item|
      question = item["question"].to_s.strip
      next if question.empty?

      entry = "Q: #{question}"
      answer = item["snippet"].to_s.strip
      entry += "\nA: #{answer}" unless answer.empty?
      questions << entry
    end
    sections << "People Also Ask:\n#{questions.join("\n")}" unless questions.empty?

    return "No results returned for query: #{query}" if sections.empty?

    sections.join("\n\n---\n\n")
  end
end
