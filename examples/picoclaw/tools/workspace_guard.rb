# frozen_string_literal: true

# restrict_to_workspace: file/exec tools may only touch paths inside the
# workspace. Symlinks are resolved before the check (picoclaw: EvalSymlinks).
class WorkspaceGuard < ToolWrapper
  PATH_KEYS = %i[file_path path cwd].freeze

  def call(arguments)
    args = arguments.to_h.transform_keys(&:to_sym)
    PATH_KEYS.each do |key|
      value = args[key]
      next if value.nil? || value.to_s.empty?

      resolved = resolve(value.to_s)
      return "Error: #{value} is outside the workspace (restrict_to_workspace)" unless resolved

      args[key] = resolved
    end
    @tool.call(args)
  end

  private

  def resolve(value)
    workspace = File.realpath(Dir.pwd)
    expanded = File.expand_path(value, Dir.pwd)
    expanded = File.realpath(expanded) if File.exist?(expanded)
    expanded if expanded == workspace || expanded.start_with?("#{workspace}#{File::SEPARATOR}")
  end
end
