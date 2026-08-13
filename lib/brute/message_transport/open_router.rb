# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/message_transport"

module Brute
  class MessageTransport
    class OpenRouter < MessageTransport
      def self.dump(message)
        message.to_h
      end

      private

        def wrap(message)
          # Coerce string keys to symbol keys if necessary
          hash = message.to_h.transform_keys(&:to_sym)
        
          case hash
          in { role: (:system | :user | :assistant | :tool) }
            # Message#initialize handles converting tool_calls & symbolising role!
            Brute::Message.new(**hash)
          else
            raise "Unrecognised message format #{message.inspect}"
          end
        end
    end
  end
end
