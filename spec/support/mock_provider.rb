# frozen_string_literal: true

# A mock LLM provider for testing. Quacks like a Brute provider
# (has name, default_model, ruby_llm_provider).
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

  # Returns self as the ruby_llm_provider — tests can stub complete() on this.
  def ruby_llm_provider
    self
  end

  def complete(messages, tools: {}, temperature: nil, model: nil, params: {}, headers: {}, thinking: nil, **rest, &block)
    @calls << { messages: messages, tools: tools, model: model }
    RubyLLM::Message.new(role: :assistant, content: 'mock response')
  end
end
