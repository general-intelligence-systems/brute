# frozen_string_literal: true

require "json"

module Hermes
  module Middleware
    module Tool
      # SafetyGuard — path normalization + workspace confinement (before).
      # The tool_request position in hermes' contract: runs BEFORE Approval so
      # downstream policy evaluates the normalized values.
      #
      #   * path-ish arguments (path, file_path, workdir, old_text… no) are
      #     expanded against the workspace so Approval sees absolute paths
      #   * with confine: true, file-tool paths escaping the workspace are
      #     refused (picoclaw's restrict_to_workspace rule)
      class SafetyGuard
        PATH_KEYS = %i[path file_path workdir].freeze
        PATH_TOOLS = %w[read_file write_file patch search_files terminal].freeze

        def initialize(app, workspace: Dir.pwd, confine: false, **_opts)
          @app = app
          @workspace = File.expand_path(workspace)
          @confine = confine
        end

        def call(env)
          normalize_paths(env) if PATH_TOOLS.include?(env[:name].to_s)

          if @confine
            violation = confinement_violation(env)
            if violation
              env[:result] = JSON.dump("error" => violation)
              return env
            end
          end

          @app.call(env)
        end

        private

        def normalize_paths(env)
          PATH_KEYS.each do |key|
            value = env[:arguments][key] || env[:arguments][key.to_s]
            next unless value.is_a?(String) && !value.empty?

            env[:arguments][key] = File.expand_path(value, @workspace)
          end
        end

        def confinement_violation(env)
          PATH_KEYS.each do |key|
            value = env[:arguments][key] || env[:arguments][key.to_s]
            next unless value.is_a?(String)

            expanded = File.expand_path(value, @workspace)
            unless expanded == @workspace || expanded.start_with?("#{@workspace}/")
              return "Refusing #{env[:name]} on '#{value}': outside the workspace (#{@workspace})."
            end
          end
          nil
        end
      end
    end
  end
end
