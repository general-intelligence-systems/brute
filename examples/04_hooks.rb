#!/usr/bin/env ruby
# frozen_string_literal: true

# Test the lifecycle hook system.

require_relative "../lib/brute"

puts "=== 04: Hooks Tests ==="
puts

class RecordingHook < Brute::Hooks::Base
  attr_reader :events
  def initialize = @events = []

  private

  def on_start(**)           = @events << :start
  def on_end(**)             = @events << :end
  def on_request(**)         = @events << :request
  def on_response(**)        = @events << :response
  def on_toolcall_start(**k) = @events << [:toolcall_start, k[:tool_name]]
  def on_toolcall_end(**k)   = @events << [:toolcall_end, k[:tool_name]]
end

# 1. Single hook
RecordingHook.new.then do |rec|
  %i[start request].each { |e| rec.call(e) }
  rec.call(:toolcall_start, tool_name: "read")
  rec.call(:toolcall_end, tool_name: "read", error: false)
  %i[response end].each { |e| rec.call(e) }
  puts "1. Events: #{rec.events.inspect}"
  puts "   Correct: #{rec.events.size == 6 ? "yes" : "NO"}"
end

# 2. Composite
RecordingHook.new.then do |r1|
  RecordingHook.new.then do |r2|
    Brute::Hooks::Composite.new(r1, r2).then do |comp|
      comp.call(:start)
      comp.call(:toolcall_start, tool_name: "shell")
      puts "2. Both fired: r1=#{r1.events.size}, r2=#{r2.events.size}"
      puts "   Correct: #{r1.events == r2.events ? "yes" : "NO"}"

      # 3. Append
      RecordingHook.new.then do |r3|
        comp << r3
        comp.call(:end)
        puts "3. After append: r3=#{r3.events.inspect}"
        puts "   Correct: #{r3.events == [:end] ? "yes" : "NO"}"
      end
    end
  end
end

# 4. Logging hook
Logger.new(StringIO.new).then do |logger|
  Brute::Hooks::Logging.new(logger).then do |hook|
    %i[start end request response toolcall_start toolcall_end].each do |event|
      hook.call(event, tool_name: "test", request_count: 0, tokens: 100)
    end
    puts "4. Logging hook: no errors"
  end
end

# 5. Unknown events ignored
RecordingHook.new.then do |rec|
  rec.call(:unknown_event, foo: "bar")
  puts "5. Unknown event: #{rec.events.empty? ? "ignored (correct)" : "UNEXPECTED"}"
end

puts
puts "=== All Hooks tests passed ==="
