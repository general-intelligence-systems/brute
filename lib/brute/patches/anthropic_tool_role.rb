# frozen_string_literal: true

# Monkey-patch: Fix Anthropic tool result message role.
#
# llm.rb stores tool results as messages with role="tool" (via @llm.tool_role).
# Anthropic's API requires tool result messages to have role="user" with
# tool_result content blocks. The Completion adapter already correctly formats
# the content (Function::Return -> {type: "tool_result", ...}), but passes
# through the "tool" role unchanged — which Anthropic rejects.
#
# This patch overrides adapt_message to set role="user" when the message
# content contains tool returns.

module Brute
  module Patches
    module AnthropicToolRole
      private

      def adapt_message
        if message.respond_to?(:role) && message.role.to_s == "tool"
          {role: "user", content: adapt_content(content)}
        else
          super
        end
      end

      # Apply the patch lazily — LLM::Anthropic is autoloaded.
      def self.apply!
        return if @applied
        @applied = true
        LLM::Anthropic::RequestAdapter::Completion.prepend(self)
      end
    end
  end
end
