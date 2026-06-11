# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Prompts
    module DoingTasks
      def self.call(ctx)
        Prompts.read("doing_tasks", ctx[:provider_name])
      end
    end
  end
end
