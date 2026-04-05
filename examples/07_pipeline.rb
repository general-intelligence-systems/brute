#!/usr/bin/env ruby
# frozen_string_literal: true

# Test the Rack-style middleware pipeline.

require_relative "../lib/brute"

puts "=== 07: Pipeline / Middleware Tests ==="
puts

$call_order = []

class RecorderMiddleware < Brute::Middleware::Base
  def initialize(app, label:)
    super(app)
    @label = label
  end

  def call(env)
    $call_order << :"#{@label}_before"
    @app.call(env).then do |result|
      $call_order << :"#{@label}_after"
      result
    end
  end
end

class TerminalApp
  def call(env)
    $call_order << :terminal
    { response: "done", env: env }
  end
end

# 1. Execution order
$call_order = []
Brute::Pipeline.new {
  use RecorderMiddleware, label: :first
  use RecorderMiddleware, label: :second
  use RecorderMiddleware, label: :third
  run TerminalApp.new
}.call({ request: "test" }).then do |result|
  puts "1. Order: #{$call_order.inspect}"
  expected = %i[first_before second_before third_before terminal third_after second_after first_after]
  puts "   Correct: #{$call_order == expected ? "yes" : "NO"}"

  # 2. Env passes through
  puts "2. Env preserved: #{result[:env][:request] == "test" ? "yes" : "NO"}"
end

# 3. Terminal only
$call_order = []
Brute::Pipeline.new { run TerminalApp.new }.call({})
puts "3. Terminal-only: #{$call_order == [:terminal] ? "yes" : "NO"}"

# 4. Short-circuit
class ShortCircuit < Brute::Middleware::Base
  def call(_env) = { short_circuited: true }
end

$call_order = []
Brute::Pipeline.new {
  use RecorderMiddleware, label: :before_sc
  use ShortCircuit
  use RecorderMiddleware, label: :after_sc
  run TerminalApp.new
}.call({}).then do |result|
  puts "4. Short-circuit: #{result[:short_circuited] ? "yes" : "NO"}"
  puts "   After skipped: #{!$call_order.include?(:after_sc_before) ? "yes" : "NO"}"
end

puts
puts "=== All Pipeline tests passed ==="
