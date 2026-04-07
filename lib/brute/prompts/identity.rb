# frozen_string_literal: true

module Brute
  module Prompts
    module Identity
      def self.call(ctx)
        Prompts.read("identity", ctx[:provider_name])
      end
    end
  end
end
