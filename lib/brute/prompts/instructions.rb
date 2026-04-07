# frozen_string_literal: true

module Brute
  module Prompts
    module Instructions
      def self.call(ctx)
        rules = ctx[:custom_rules]
        return nil if rules.nil? || rules.strip.empty?

        <<~TXT
          # Project-Specific Rules

          #{rules}
        TXT
      end
    end
  end
end
