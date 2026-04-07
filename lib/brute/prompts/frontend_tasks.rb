# frozen_string_literal: true

module Brute
  module Prompts
    module FrontendTasks
      TEXT = <<~TXT
        # Frontend tasks

        When doing frontend design tasks, avoid collapsing into bland, generic layouts.
        - Ensure the page loads properly on both desktop and mobile.
        - Overall: Avoid boilerplate layouts and interchangeable UI patterns. Vary themes, type families, and visual languages across outputs.

        Exception: If working within an existing website or design system, preserve the established patterns, structure, and visual language.
      TXT

      def self.call(_ctx)
        TEXT
      end
    end
  end
end
