# frozen_string_literal: true

module Brute
  module Prompts
    module SecurityAndSafety
      TEXT = <<~TXT
        # Security and Safety Rules
        - **Explain Critical Commands:** Before executing shell commands that modify the file system, codebase, or system state, provide a brief explanation of the command's purpose and potential impact.
        - **Security First:** Always apply security best practices. Never introduce code that exposes, logs, or commits secrets, API keys, or other sensitive information.
      TXT

      def self.call(_ctx)
        TEXT
      end
    end
  end
end
