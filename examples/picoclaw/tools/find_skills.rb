# frozen_string_literal: true

require "json"
require_relative "skill_registries"

# find_skills — picoclaw `pkg/tools/integration/skills_search.go`.
# Searches the configured registries (clawhub + github by default), cached by
# the trigram-Jaccard LRU search cache (50 entries, 300s).
class FindSkills < Brute::Tool
  description "Search for installable skills from skill registries. Returns skill slugs, " \
              "descriptions, versions, and relevance scores. Use this to discover skills before " \
              "installing them with install_skill."
  params({
    "type" => "object",
    "properties" => {
      "query" => { "type" => "string", "description" => "Search query describing the desired skill capability (e.g., 'github integration', 'database management')" },
      "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 20, "description" => "Maximum number of results to return (1-20, default 5)" },
    },
    "required" => ["query"],
  })

  def initialize(registries:, cache: SkillRegistries::SearchCache.new)
    @registries = registries
    @cache = cache
  end

  def name = "find_skills"

  def execute(query: nil, limit: nil, **_args)
    query = query.to_s.strip.downcase
    return "query is required and must be a non-empty string" if query.empty?

    limit = limit.is_a?(Numeric) && limit >= 1 && limit <= 20 ? limit.to_i : 5

    if (cached = @cache.get(query))
      return format_results(query, cached, cached: true)
    end

    results = @registries.flat_map do |registry|
      begin
        registry.search(query, limit)
      rescue StandardError => e
        warn "find_skills: #{registry.name} search failed: #{e.message}"
        []
      end
    end

    @cache.put(query, results) if results.any?
    format_results(query, results, cached: false)
  rescue StandardError => e
    "skill search failed: #{e.message}"
  end

  private

  def format_results(query, results, cached:)
    return %(No skills found for query: "#{query}") if results.empty?

    out = +"Found #{results.size} skills for \"#{query}\"#{" (cached)" if cached}:\n\n"
    results.each_with_index do |r, i|
      out << "#{i + 1}. **#{r[:slug]}**"
      out << " v#{r[:version]}" unless r[:version].to_s.empty?
      out << format("  (score: %.3f, registry: %s)\n", r[:score], r[:registry])
      out << "   Name: #{r[:display_name]}\n" if !r[:display_name].to_s.empty? && r[:display_name] != r[:slug]
      out << "   #{r[:summary]}\n" unless r[:summary].to_s.empty?
      out << "\n"
    end
    out << "Use install_skill with the slug to install a skill."
    out
  end
end
