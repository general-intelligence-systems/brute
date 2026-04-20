# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

# Monkey-patch: Guard LLM::Buffer against nil entries.
#
# llm.rb's Context#talk can sometimes concatenate nil into the message
# buffer (e.g. when response parsing yields a nil choice). This causes
# NoMethodError when the buffer is iterated (assistant?, tool_return?, etc).
#
# This patch overrides concat to filter out nils before they enter the buffer.

module Brute
  module Patches
    module BufferNilGuard
      def concat(messages)
        super(Array(messages).compact)
      end
    end
  end
end

LLM::Buffer.prepend(Brute::Patches::BufferNilGuard)
