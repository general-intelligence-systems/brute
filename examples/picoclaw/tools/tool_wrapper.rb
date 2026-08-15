# frozen_string_literal: true

# Base class for tool wrappers — duck-types the Brute::Tools::Adapter
# interface so wrappers compose and drop into ToolPipeline unchanged.
class ToolWrapper
  def initialize(tool)
    @tool = Brute::Tools::Adapter.wrap(tool)
  end

  def name = @tool.name
  def description = @tool.description
  def params = @tool.params
  def params_schema = @tool.respond_to?(:params_schema) ? @tool.params_schema : nil

  def call(arguments) = @tool.call(arguments)
end
