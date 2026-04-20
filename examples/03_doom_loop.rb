#!/usr/bin/env ruby
# frozen_string_literal: true

# Doom loop detection: catches agents repeating the same tool calls.

require_relative "../lib/brute"

FakeFunction = Struct.new(:name, :arguments)
FakeMessage = Struct.new(:functions) do
  def assistant? = true
  def respond_to?(m, *) = m == :functions ? true : super
end

detector = Brute::DoomLoopDetector.new(threshold: 3)

# Simulate an agent stuck reading the same file over and over
messages = Array.new(4) { FakeMessage.new([FakeFunction.new("read", "/app.rb")]) }

reps = detector.detect(messages)
puts detector.warning_message(reps) if reps
