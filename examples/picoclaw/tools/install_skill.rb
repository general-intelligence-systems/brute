# frozen_string_literal: true

require "json"

# install_skill — picoclaw `pkg/tools/integration/skills_install.go`.
# Gate: tools.skills.enabled AND tools.install_skill.enabled (both default
# true). Installs to {workspace}/skills/{slug}/ with registry moderation
# (malware blocked, suspicious warned); force=true backs up and restores on
# failure; writes .skill-origin.json.
# Scaffold: no-op handler, returns a JSON error string.
class InstallSkill < Brute::Tool
  description "Install a skill from a registry by slug. Defaults to GitHub when registry is " \
              "omitted. Downloads and extracts the skill into the workspace. Use find_skills " \
              "first to discover available skills."
  params({
    "type" => "object",
    "properties" => {
      "slug" => { "type" => "string", "description" => "The unique slug of the skill to install (e.g., 'github', 'docker-compose')" },
      "version" => { "type" => "string", "description" => "Specific version to install (optional, defaults to latest)" },
      "registry" => { "type" => "string", "description" => "Registry to install from (optional, defaults to 'github')" },
      "force" => { "type" => "boolean", "description" => "Force reinstall if skill already exists (default false)" },
    },
    "required" => ["slug"],
  })

  def name = "install_skill"

  def execute(**_args)
    JSON.dump("error" => "not implemented", "tool" => "install_skill")
  end
end
