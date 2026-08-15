# frozen_string_literal: true

require "json"

# find_skills — picoclaw `pkg/tools/integration/skills_search.go`.
# Gate: tools.skills.enabled AND tools.find_skills.enabled (both default true);
# registries clawhub (https://clawhub.ai) + github; search cache
# {max_size: 50, ttl_seconds: 300} with trigram-Jaccard fuzzy hits.
# Scaffold: no-op handler, returns a JSON error string.
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

  def name = "find_skills"

  def execute(**_args)
    JSON.dump("error" => "not implemented", "tool" => "find_skills")
  end
end
