# frozen_string_literal: true

module Brute
  module Prompts
    module BuildSwitch
      TEXT = <<~TXT
        <system-reminder>
        Your operational mode has changed from plan to build.
        You are no longer in read-only mode.
        You are permitted to make file changes, run shell commands, and utilize your arsenal of tools as needed.
        </system-reminder>
      TXT

      def self.call(_ctx)
        TEXT
      end
    end
  end
end
