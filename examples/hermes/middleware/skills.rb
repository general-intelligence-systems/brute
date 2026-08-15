# frozen_string_literal: true

require_relative "../skill_store"
require_relative "../tools/skills_list"
require_relative "../tools/skill_view"
require_relative "../tools/skill_manage"

module Hermes
  module Middleware
    # Skills — procedural memory (per-turn). Port of hermes-agent's skills
    # surface on top of brute's spec-compliant Brute::Skill parsing.
    #
    # Before the turn:
    #   - scans the skill dirs via Hermes::SkillStore (platform-gated,
    #     deduped, category-labelled)
    #   - renders the skills index into env[:metadata][:skills_prompt] —
    #     PromptTiers places it at the FRONT of the volatile band
    #   - installs skills_list / skill_view / skill_manage via
    #     env[:provided_tools] (shadowing the static scaffolds)
    #
    # The index rendering follows hermes' build_skills_system_prompt: the
    # "mandatory" steering prose, category-grouped lines, and the load-first
    # doctrine. (Slash-command injection and the curator are driver-side.)
    class Skills
      INDEX_PROSE =
        "## Skills (mandatory)\n" \
        "Before replying, scan the skills below. If a skill matches or is even partially relevant " \
        "to your task, you MUST load it with skill_view(name) and follow its instructions. " \
        "Err on the side of loading — it is always better to have context you don't need " \
        "than to miss critical steps, pitfalls, or established workflows. " \
        "Skills contain specialized knowledge — API endpoints, tool-specific commands, " \
        "and proven workflows that outperform general-purpose approaches. Load the skill " \
        "even if you think you could handle the task with basic tools like web_search or terminal. " \
        "Skills also encode the user's preferred approach, conventions, and quality standards " \
        "for tasks like code review, planning, and testing — load them even for tasks you " \
        "already know how to do, because the skill defines how it should be done here.\n" \
        "If a skill has issues, fix it with skill_manage(action='patch').\n" \
        "After difficult/iterative tasks, offer to save as a skill. " \
        "If a skill you loaded was missing steps, had wrong commands, or needed " \
        "pitfalls you discovered, update it before finishing.\n"

      INDEX_FOOTER = "Only proceed without loading a skill if genuinely none are relevant to the task."

      def initialize(app, dirs: [File.join(Dir.pwd, "skills")])
        @app = app
        @dirs = Array(dirs)
      end

      def call(env)
        store = Hermes::SkillStore.new(dirs: @dirs)
        skills = store.all

        env[:skill_store] = store
        env[:skills] = skills.map { |e| e[:skill] }
        env[:metadata] ||= {}
        env[:metadata][:skills] = env[:skills]

        prompt = render_index(skills)
        env[:metadata][:skills_prompt] = prompt if prompt

        env[:provided_tools] = Array(env[:provided_tools]) + [
          HermesTools::SkillsList.new(store),
          HermesTools::SkillView.new(store),
          HermesTools::SkillManage.new(store),
        ]

        @app.call(env)
      end

      private

      # hermes' build_skills_system_prompt: steering prose + category-grouped
      # <available_skills> lines + footer. nil when there are no skills.
      def render_index(skills)
        return nil if skills.empty?

        by_category = skills.group_by { |e| e[:category] }
        lines = []
        by_category.keys.sort.each do |category|
          lines << "  #{category}:"
          by_category[category].sort_by { |e| e[:name] }.each do |e|
            lines << (e[:description].to_s.empty? ? "    - #{e[:name]}" : "    - #{e[:name]}: #{e[:description]}")
          end
        end

        INDEX_PROSE +
          "\n<available_skills>\n" + lines.join("\n") + "\n</available_skills>\n" \
          "\n" + INDEX_FOOTER
      end
    end
  end
end
