# frozen_string_literal: true

require "json"

module HermesTools
  # skills_list — progressive disclosure tier 2: minimal skill metadata.
  # Port of hermes-agent tools/skills_tool.py:789. The store is injected per
  # turn by Hermes::Middleware::Skills; a storeless instance reports empty.
  class SkillsList < Brute::Tool
    description "List all available skills (minimal metadata: name, description, category). " \
                "Use skill_view(name) to load full content, tags, and linked files."
    params({
      "type" => "object",
      "properties" => {
        "category" => { "type" => "string", "description" => "Optional category filter (e.g. 'mlops')." },
      },
      "required" => [],
    })

    def initialize(store = nil)
      @store = store
    end

    def name = "skills_list"

    def execute(category: nil)
      skills = @store ? @store.all : []
      skills = skills.select { |s| s[:category] == category } if category

      JSON.dump(
        "success" => true,
        "skills" => skills.map { |s| { "name" => s[:name], "description" => s[:description], "category" => s[:category] } },
        "categories" => skills.map { |s| s[:category] }.uniq.sort,
        "count" => skills.size,
        "hint" => "Use skill_view(name) to see full content, tags, and linked files",
      )
    end
  end
end
