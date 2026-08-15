# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../write_approval"

module HermesTools
  # skill_manage — create/patch/maintain skills. Port of hermes-agent
  # tools/skill_manager_tool.py: the six actions plus the guard stack:
  #
  #   1. Protection preflight (edit/patch/delete/write_file/remove_file on an
  #      existing skill): background-review writers may only touch
  #      curator-managed (created_by: "agent") skills; pinned refuses even
  #      content updates from the fork.
  #   2. Curator consolidation guard: a background `delete` must declare
  #      absorbed_into=<umbrella> (which must exist on disk) — bare deletes
  #      from the fork are refused outright (fail closed, hermes #29912).
  #   3. `delete` refuses pinned skills for EVERYONE (foreground included);
  #      patch/edit/write_file/remove_file on pinned go through in the
  #      foreground so the agent can keep improving them.
  #   4. Write gate: when skills.write_approval is on, every mutation stages
  #      to the pending store (skills are too big to review inline).
  class SkillManage < Brute::Tool
    description "Create and maintain skills (procedural memory). Actions: create, edit, patch, " \
                "delete, write_file, remove_file. Prefer patching existing class-level skills " \
                "over creating narrow one-off skills."
    params({
      "type" => "object",
      "properties" => {
        "action" => { "type" => "string", "enum" => %w[create edit patch delete write_file remove_file] },
        "name" => { "type" => "string", "description" => "Skill name (lowercase-hyphen, matches its directory)." },
        "content" => { "type" => "string", "description" => "Full SKILL.md text for create/edit." },
        "category" => { "type" => "string", "description" => "Category directory for create (default: custom)." },
        "file_path" => { "type" => "string", "description" => "Support file path for write_file/remove_file/patch (e.g. 'references/api.md')." },
        "file_content" => { "type" => "string", "description" => "Content for write_file." },
        "old_string" => { "type" => "string", "description" => "Text to find for patch." },
        "new_string" => { "type" => "string", "description" => "Replacement text for patch (empty string deletes the match)." },
        "replace_all" => { "type" => "boolean", "description" => "Replace all occurrences (default false)." },
        "absorbed_into" => { "type" => "string", "description" => "Umbrella skill this one was merged into (required for background deletes)." },
      },
      "required" => %w[action name],
    })

    MUTATING = %w[create edit patch delete write_file remove_file].freeze
    GUARDED = %w[edit patch delete write_file remove_file].freeze

    def initialize(store = nil)
      @store = store
    end

    def name = "skill_manage"

    def execute(action:, name:, content: nil, category: nil, file_path: nil, file_content: nil,
                old_string: nil, new_string: nil, replace_all: false, absorbed_into: nil)
      return err("Skills are not available (no store installed).") unless @store
      return err("action must be one of: #{MUTATING.join(', ')}") unless MUTATING.include?(action.to_s)

      name_error = validate_name(name)
      return name_error if name_error

      payload = {
        "action" => action, "name" => name, "content" => content, "category" => category,
        "file_path" => file_path, "file_content" => file_content, "old_string" => old_string,
        "new_string" => new_string, "replace_all" => replace_all, "absorbed_into" => absorbed_into,
      }

      # 1. Protection preflight (existing skills only).
      if GUARDED.include?(action) && @store.find(name)
        guarded = protection_guard(name, action)
        return JSON.dump(guarded) if guarded
      end

      # 2. Curator consolidation guard (background deletes need absorbed_into).
      if action == "delete" && Hermes::WriteApproval.background? && absorbed_into.to_s.strip.empty?
        return err("Refusing background delete of '#{name}' without absorbed_into. " \
                   "Consolidation deletes must name the umbrella skill that absorbed the content.")
      end

      # 3. Pinned delete is refused for everyone.
      if action == "delete" && @store.pinned?(name)
        return err("Refusing to delete pinned skill '#{name}'. Unpin it first (hermes curator unpin).")
      end

      # 4. Write gate — skills always stage when the gate is on.
      gated = write_gate(payload)
      return JSON.dump(gated) if gated

      result = dispatch(action, name, content, category, file_path, file_content,
                        old_string, new_string, replace_all, absorbed_into)

      # Telemetry + provenance.
      if result[:success]
        @store.bump_patch(name) if %w[patch edit].include?(action)
        if action == "create" && Hermes::WriteApproval.background?
          @store.set_provenance(name, created_by: "agent")
        end
      end
      JSON.dump(result)
    end

    # Replay a staged write, bypassing the gate (called on approval).
    def self.apply_pending(payload, store)
      new(store).execute(**payload.transform_keys(&:to_sym).merge({}))
    end

    private

    def err(message)
      JSON.dump("success" => false, "error" => message)
    end

    def validate_name(name)
      if name.to_s.empty? || name.length > 64 || name !~ /\A[a-z0-9]+(-[a-z0-9]+)*\z/
        err("Invalid skill name '#{name}'. Use 1-64 chars of lowercase letters, digits, single hyphens.")
      end
    end

    # The protection matrix (hermes _background_review_write_guard).
    def protection_guard(name, action)
      return nil unless Hermes::WriteApproval.background?
      return nil if @store.writable_by?(name, origin: "background_review")

      if @store.pinned?(name)
        return {
          success: false,
          error: "Refusing background #{action} for pinned skill '#{name}'. " \
                 "Pinned skills are user-controlled; only a foreground session can change one.",
        }
      end
      {
        success: false,
        error: "Refusing background #{action} for '#{name}': not curator-managed " \
               "(bundled, hub-installed, and user-owned skills are protected). " \
               "Recommend 'hermes curator adopt #{name}' instead.",
      }
    end

    def write_gate(payload)
      return nil unless Hermes::WriteApproval.enabled?(Hermes::WriteApproval::SKILLS)

      summary = "#{payload['action']} skill #{payload['name']}"
      decision = Hermes::WriteApproval.evaluate_gate(
        Hermes::WriteApproval::SKILLS, inline_summary: summary, inline_detail: payload["content"].to_s
      )
      return nil if decision.allow
      return { "success" => false, "error" => decision.message } if decision.blocked

      record = Hermes::WriteApproval.stage_write(
        Hermes::WriteApproval::SKILLS, payload,
        summary: summary, origin: Hermes::WriteApproval.current_origin
      )
      { "success" => true, "staged" => true, "pending_id" => record["id"], "message" => decision.message }
    end

    def dispatch(action, name, content, category, file_path, file_content,
                 old_string, new_string, replace_all, absorbed_into)
      case action
      when "create"
        return { success: false, error: "content is required for 'create'. Provide the full SKILL.md text (frontmatter + body)." } if content.to_s.empty?

        create_skill(name, content, category)
      when "edit"
        return { success: false, error: "content is required for 'edit'. Provide the full updated SKILL.md text." } if content.to_s.empty?

        edit_skill(name, content)
      when "patch"
        return { success: false, error: "old_string is required for 'patch'. Provide the text to find." } if old_string.to_s.empty?
        return { success: false, error: "new_string is required for 'patch'. Use empty string to delete matched text." } if new_string.nil?

        patch_skill(name, old_string, new_string, file_path, replace_all)
      when "delete"       then delete_skill(name, absorbed_into)
      when "write_file"
        return { success: false, error: "file_path is required for 'write_file'. Example: 'references/api-guide.md'" } if file_path.to_s.empty?

        write_support_file(name, file_path, file_content.to_s)
      when "remove_file"
        return { success: false, error: "file_path is required for 'remove_file'." } if file_path.to_s.empty?

        remove_support_file(name, file_path)
      end
    end

    # -- Actions ---------------------------------------------------------------

    def create_skill(name, content, category)
      return { success: false, error: "Skill '#{name}' already exists. Use edit or patch." } if @store.find(name)

      category = category.to_s.strip.empty? ? "custom" : category.to_s.strip
      return { success: false, error: "Invalid category '#{category}'." } unless category =~ /\A[\w-]+\z/

      dir = File.join(@store.dirs.first, category, name)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), content, encoding: Encoding::UTF_8)
      { success: true, message: "Skill '#{name}' created in #{category}/.", path: File.join(dir, "SKILL.md") }
    end

    def edit_skill(name, content)
      entry = @store.find(name)
      return { success: false, error: "Skill '#{name}' not found." } unless entry

      atomic_write(entry[:path], content)
      { success: true, message: "Skill '#{name}' updated.", path: entry[:path] }
    end

    def patch_skill(name, old_string, new_string, file_path, replace_all)
      entry = @store.find(name)
      return { success: false, error: "Skill '#{name}' not found." } unless entry

      target = entry[:path]
      if file_path
        target = contained_path(File.dirname(entry[:path]), file_path)
        return { success: false, error: "Invalid file_path '#{file_path}' — must stay within the skill directory." } unless target
        return { success: false, error: "File '#{file_path}' not found in skill '#{name}'." } unless File.exist?(target)
      end

      body = File.read(target, encoding: Encoding::UTF_8)
      return { success: false, error: "old_string not found in #{File.basename(target)}." } unless body.include?(old_string)

      if !replace_all && body.scan(old_string).size > 1
        return { success: false, error: "old_string matches #{body.scan(old_string).size} times — be more specific or pass replace_all=true." }
      end

      updated = replace_all ? body.gsub(old_string) { new_string } : body.sub(old_string) { new_string }
      atomic_write(target, updated)
      { success: true, message: "Patched #{File.basename(target)} in '#{name}'.", path: target }
    end

    def delete_skill(name, absorbed_into)
      entry = @store.find(name)
      return { success: false, error: "Skill '#{name}' not found." } unless entry

      unless absorbed_into.to_s.strip.empty?
        return { success: false, error: "absorbed_into umbrella '#{absorbed_into}' does not exist on disk." } unless @store.find(absorbed_into.strip)
      end

      FileUtils.rm_rf(File.dirname(entry[:path]))
      { success: true, message: "Skill '#{name}' deleted#{absorbed_into.to_s.empty? ? "" : " (absorbed into #{absorbed_into})"}." }
    end

    def write_support_file(name, file_path, file_content)
      entry = @store.find(name)
      return { success: false, error: "Skill '#{name}' not found." } unless entry

      target = contained_path(File.dirname(entry[:path]), file_path)
      return { success: false, error: "Invalid file_path '#{file_path}' — must stay within the skill directory." } unless target

      FileUtils.mkdir_p(File.dirname(target))
      atomic_write(target, file_content)
      { success: true, message: "Wrote #{file_path} in '#{name}'.", path: target }
    end

    def remove_support_file(name, file_path)
      entry = @store.find(name)
      return { success: false, error: "Skill '#{name}' not found." } unless entry

      target = contained_path(File.dirname(entry[:path]), file_path)
      return { success: false, error: "Invalid file_path '#{file_path}' — must stay within the skill directory." } unless target
      return { success: false, error: "File '#{file_path}' not found in skill '#{name}'." } unless File.exist?(target)

      File.delete(target)
      { success: true, message: "Removed #{file_path} from '#{name}'." }
    end

    # -- Helpers ----------------------------------------------------------------

    def contained_path(skill_dir, file_path)
      return nil if file_path.start_with?("/", "~")

      resolved = Pathname.new(File.join(skill_dir, file_path)).cleanpath
      base = Pathname.new(skill_dir).cleanpath
      resolved.to_s.start_with?("#{base}/") ? resolved.to_s : nil
    end

    def atomic_write(path, content)
      tmp = "#{path}.tmp"
      File.write(tmp, content, encoding: Encoding::UTF_8)
      File.rename(tmp, path)
    end
  end
end
