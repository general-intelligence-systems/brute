# frozen_string_literal: true

# A mock LLM provider for testing. Quacks like a provider (has name,
# default_model, complete).
class MockProvider
  attr_reader :calls

  def initialize
    @calls = []
  end

  def name
    :mock
  end

  def default_model
    'mock-model'
  end

  def complete(messages, tools: {}, temperature: nil, model: nil, params: {}, headers: {}, thinking: nil, **rest, &block)
    @calls << { messages: messages, tools: tools, model: model }
    Brute::Message.new(role: :assistant, content: 'mock response')
  end
end
