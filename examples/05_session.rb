#!/usr/bin/env ruby
# frozen_string_literal: true

# Test session save/restore/list/delete.

require_relative "../lib/brute"
require "json"

DIR = File.expand_path("tmp/session_test", __dir__)
FileUtils.rm_rf(DIR)

puts "=== 05: Session Tests ==="
puts

# 1. Create
Brute::Session.new(dir: DIR).then do |s|
  puts "1. Created: #{s.id[0..7]}..."

  # 2. List before save
  Brute::Session.list(dir: DIR).then { |l| puts "2. Before save: #{l.size} sessions" }

  # 3. Write fake session files
  File.write(s.path, "{}")
  s.path.sub(/\.json$/, ".meta.json").then do |meta|
    File.write(meta, JSON.generate(id: s.id, title: "Test Session", saved_at: Time.now.iso8601, metadata: { cwd: "/tmp" }))
  end
  puts "3. Wrote fake session"

  # 4. List after save
  Brute::Session.list(dir: DIR).then do |sessions|
    puts "4. After save: #{sessions.size} session(s)"
    puts "   Title: #{sessions.first[:title]}"
    puts "   Correct: #{sessions.first[:title] == "Test Session" ? "yes" : "NO"}"
  end

  # 5. Second session
  Brute::Session.new(dir: DIR).then do |s2|
    File.write(s2.path, "{}")
    File.write(s2.path.sub(/\.json$/, ".meta.json"), JSON.generate(id: s2.id, title: "Second", saved_at: Time.now.iso8601, metadata: {}))
    Brute::Session.list(dir: DIR).then { |l| puts "5. Two sessions: #{l.size == 2 ? "yes" : "NO"}" }
  end

  # 6. Delete
  s.delete
  Brute::Session.list(dir: DIR).then { |l| puts "6. After delete: #{l.size == 1 ? "1 remaining (correct)" : "UNEXPECTED: #{l.size}"}" }
end

FileUtils.rm_rf(DIR)
puts
puts "=== All Session tests passed ==="
