# frozen_string_literal: true

# A mock LLM provider that returns pre-scripted responses.
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

  def user_role
    :user
  end

  def system_role
    :system
  end

  def assistant_role
    :assistant
  end

  def tool_role
    :tool
  end

  def tracer
    nil
  end

  def tracer=(*); end

  def complete(prompt, params = {})
    @calls << { prompt: prompt, params: params }
    MockResponse.new(content: 'mock response')
  end
end
