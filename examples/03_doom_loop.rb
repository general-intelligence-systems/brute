#!/usr/bin/env ruby
# frozen_string_literal: true

# Test the DoomLoopDetector — detects repeating tool call patterns.

require_relative "../lib/brute"

puts "=== 03: DoomLoopDetector Tests ==="
puts

detector = Brute::DoomLoopDetector.new(threshold: 3)

FakeFunction = Struct.new(:name, :arguments)
FakeMessage = Struct.new(:functions) do
  def assistant? = true
  def respond_to?(m, *) = m == :functions ? true : super
end

# 1. No repetition
[
  FakeMessage.new([FakeFunction.new("read", "a")]),
  FakeMessage.new([FakeFunction.new("write", "b")]),
  FakeMessage.new([FakeFunction.new("shell", "c")]),
].then { |msgs| detector.detect(msgs) }
 .then { |r| puts "1. Different calls: #{r.nil? ? "no loop (correct)" : "UNEXPECTED: #{r}"}" }

# 2. Same call repeated 3 times
[
  FakeMessage.new([FakeFunction.new("read", "/foo")]),
  FakeMessage.new([FakeFunction.new("read", "/foo")]),
  FakeMessage.new([FakeFunction.new("read", "/foo")]),
].then { |msgs| detector.detect(msgs) }
 .then { |r| puts "2. Same call x3: #{r == 3 ? "detected (correct)" : "UNEXPECTED: #{r}"}" }

# 3. Pattern [A,B] repeated 3 times
[
  FakeMessage.new([FakeFunction.new("read", "x")]),
  FakeMessage.new([FakeFunction.new("write", "y")]),
  FakeMessage.new([FakeFunction.new("read", "x")]),
  FakeMessage.new([FakeFunction.new("write", "y")]),
  FakeMessage.new([FakeFunction.new("read", "x")]),
  FakeMessage.new([FakeFunction.new("write", "y")]),
].then { |msgs| detector.detect(msgs) }
 .then { |r| puts "3. Pattern [A,B] x3: #{r == 3 ? "detected (correct)" : "UNEXPECTED: #{r}"}" }

# 4. Under threshold
[
  FakeMessage.new([FakeFunction.new("read", "/foo")]),
  FakeMessage.new([FakeFunction.new("read", "/foo")]),
].then { |msgs| detector.detect(msgs) }
 .then { |r| puts "4. Same call x2: #{r.nil? ? "no loop (correct)" : "UNEXPECTED: #{r}"}" }

# 5. Warning message
detector.warning_message(4).then do |msg|
  puts "5. Warning:"
  msg.lines.each { |l| puts "   #{l}" }
end

puts
puts "=== All DoomLoopDetector tests passed ==="
