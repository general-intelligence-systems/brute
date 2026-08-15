# frozen_string_literal: true

require "json"

module Hermes
  module Middleware
    module Tool
      # ReadLoopGuard — the anti read-loop tracker (before). Port of
      # hermes-agent's read-loop tracking (model_tools.py:1440 — reset for
      # non-read tools).
      #
      # Repeated reads of the same path without any write/progress in between
      # get a warning, then a block. Any non-read tool resets the tracker
      # (progress was made).
      class ReadLoopGuard
        READ_TOOLS = %w[read_file search_files].freeze
        WARN_AFTER = 3
        BLOCK_AFTER = 5

        def initialize(app, **_opts)
          @app = app
          @reads = Hash.new(0)
        end

        def call(env)
          name = env[:name].to_s

          unless READ_TOOLS.include?(name)
            @reads.clear
            return @app.call(env)
          end

          key = "#{name}:#{env[:arguments][:path] || env[:arguments]['path']}"
          @reads[key] += 1

          if @reads[key] > BLOCK_AFTER
            env[:result] = JSON.dump(
              "error" => "ReadLoopGuard: '#{key}' has been read #{@reads[key]} times without progress. " \
                         "Stop re-reading and proceed with what you already have.",
            )
            return env
          end

          if @reads[key] > WARN_AFTER
            @app.call(env)
            result = JSON.parse(env[:result]) rescue nil
            if result.is_a?(Hash)
              result["read_loop_warning"] = "You have read this path #{@reads[key]} times — use the content you have instead of re-reading."
              env[:result] = JSON.dump(result)
            end
            return env
          end

          @app.call(env)
        end
      end
    end
  end
end
