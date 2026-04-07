# frozen_string_literal: true

module Brute
  module Prompts
    module GitSafety
      TEXT = <<~TXT
        # Git safety
        - NEVER commit changes unless the user explicitly asks you to.
        - NEVER use destructive commands like `git reset --hard` or `git checkout --` unless specifically requested.
        - Do not amend commits unless explicitly requested.
        - Prefer non-interactive git commands. Avoid `git rebase -i` or `git add -i`.
      TXT

      def self.call(_ctx)
        TEXT
      end
    end
  end
end
