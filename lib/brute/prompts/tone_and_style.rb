# frozen_string_literal: true

module Brute
  module Prompts
    module ToneAndStyle
      def self.call(ctx)
        Prompts.read("tone_and_style", ctx[:provider_name])
      end
    end
  end
end
