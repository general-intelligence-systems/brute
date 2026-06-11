# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Prompts
    module ToolUsage
      def self.call(ctx)
        Prompts.read("tool_usage", ctx[:provider_name])
      end
    end
  end
end
