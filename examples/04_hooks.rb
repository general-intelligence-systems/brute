#!/usr/bin/env ruby
# frozen_string_literal: true

# Lifecycle hooks: observe agent events (start, end, tool calls, etc.)

require_relative "../lib/brute"

class TimingHook < Brute::Hooks::Base
  attr_reader :events

  def initialize = @events = []

  private

  def on_start(**)           = @events << [:start, Time.now]
  def on_end(**)             = @events << [:end, Time.now]
  def on_toolcall_start(**k) = @events << [:tool, k[:tool_name]]
end

hook = TimingHook.new
hook.call(:start)
hook.call(:toolcall_start, tool_name: "read")
hook.call(:toolcall_start, tool_name: "patch")
hook.call(:end)

puts hook.events.map { |e| e.first == :tool ? "  tool: #{e.last}" : e.first }.join("\n")
