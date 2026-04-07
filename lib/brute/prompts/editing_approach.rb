# frozen_string_literal: true

module Brute
  module Prompts
    module EditingApproach
      TEXT = <<~TXT
        # Editing Approach

        - The best changes are often the smallest correct changes.
        - When you are weighing two correct approaches, prefer the more minimal one (less new names, helpers, tests, etc).
        - Keep things in one function unless composable or reusable.
        - Do not add backward-compatibility code unless there is a concrete need, such as persisted data, shipped behavior, external consumers, or an explicit user requirement; if unclear, ask one short question instead of guessing.
      TXT

      def self.call(_ctx)
        TEXT
      end
    end
  end
end
