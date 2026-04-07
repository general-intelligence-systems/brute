# frozen_string_literal: true

module Brute
  module Prompts
    module CodeStyle
      TEXT = <<~TXT
        # Code style
        - IMPORTANT: DO NOT ADD ***ANY*** COMMENTS unless asked
      TXT

      def self.call(_ctx)
        TEXT
      end
    end
  end
end
