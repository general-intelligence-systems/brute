# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "skill_registries"

# install_skill — picoclaw `pkg/tools/integration/skills_install.go`.
# Installs a registry skill into <workspace>/skills/<dir>/: workspace-mutexed,
# force=true backs up the existing dir and restores on failure, malware-blocked
# archives are deleted + errored, suspicious archives warn, and
# .skill-origin.json records the provenance.
class InstallSkill < Brute::Tool
  MUTEX = Mutex.new

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

  def initialize(registries:, workspace: Dir.pwd)
    @registries = registries.to_h { |r| [r.name, r] }
    @workspace = workspace
  end

  def name = "install_skill"

  def execute(slug: nil, version: nil, registry: nil, force: false, **_args)
    MUTEX.synchronize do
      slug = slug.to_s.strip
      return "identifier is required and must be a non-empty string" if slug.empty?

      registry_name = registry.to_s.empty? ? "github" : registry
      unless SkillRegistries.valid_identifier?(registry_name)
        return %(invalid registry "#{registry_name}": error: identifier must not contain path separators or '..' to prevent directory traversal)
      end

      registry = @registries[registry_name]
      return %(registry "#{registry_name}" not found) unless registry

      unless SkillRegistries.valid_identifier?(slug)
        return %(invalid slug "#{slug}": error: identifier must not contain path separators or '..' to prevent directory traversal)
      end

      dir_name = registry_name == "github" ? registry.resolve_dir_name(slug) : slug
      skills_dir = File.join(@workspace, "skills")
      target_dir = File.join(skills_dir, dir_name)

      backup_dir = nil
      if File.exist?(target_dir)
        unless force == true
          return %(skill "#{slug}" already installed at #{target_dir}. Use force=true to reinstall.)
        end

        backup_dir = File.join(skills_dir, ".#{dir_name}.picoclaw-backup-#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}")
        FileUtils.mv(target_dir, backup_dir)
      end

      begin
        result = registry.download_and_install(slug, version.to_s, target_dir)

        raise "skill #{slug.inspect} is flagged as malicious and cannot be installed" if result[:malware_blocked]
        raise "failed to install #{slug.inspect}: registry archive is not a valid skill" unless File.exist?(File.join(target_dir, "SKILL.md"))

        persist_origin(target_dir, registry_name, slug, result[:version])
        FileUtils.rm_rf(backup_dir) if backup_dir

        output = +""
        output << "⚠️ Warning: skill \"#{slug}\" is flagged as suspicious (may contain risky patterns).\n\n" if result[:suspicious]
        output << "Successfully installed skill \"#{slug}\" v#{result[:version]} from #{registry_name} registry.\nLocation: #{target_dir}\n"
        output << "Description: #{result[:summary]}\n" unless result[:summary].to_s.empty?
        output << "\nThe skill is now available and can be loaded in the current session."
        output
      rescue StandardError => e
        FileUtils.rm_rf(target_dir)
        FileUtils.mv(backup_dir, target_dir) if backup_dir && File.exist?(backup_dir)
        return e.message.start_with?("skill ", "failed to install") ? e.message : "failed to install #{slug.inspect}: #{e.message}"
      end
    end
  end

  private

  def persist_origin(target_dir, registry_name, slug, version)
    meta = { "registry" => registry_name, "slug" => slug, "version" => version.to_s,
             "installed_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
    tmp = File.join(target_dir, ".skill-origin.json.tmp")
    File.write(tmp, "#{JSON.pretty_generate(meta)}\n")
    File.rename(tmp, File.join(target_dir, ".skill-origin.json"))
  end
end
