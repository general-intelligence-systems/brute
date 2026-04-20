#!/usr/bin/env ruby
# frozen_string_literal: true

# Sessions: persist and resume agent conversations.

require_relative "../lib/brute"

dir = File.expand_path("tmp/session_example", __dir__)
FileUtils.rm_rf(dir)

# Create a session and write metadata so it appears in the listing
session = Brute::Session.new(dir: dir)
File.write(session.path, "{}")
meta_path = session.path.sub(/\.json$/, ".meta.json")
File.write(meta_path, JSON.generate(
  id: session.id,
  title: "Fix auth bug",
  saved_at: Time.now.iso8601,
  metadata: { cwd: Dir.pwd }
))

# List all sessions (newest first)
sessions = Brute::Session.list(dir: dir)

puts sessions.map { |s| "#{s[:id][0..7]}  #{s[:title]}" }.join("\n")

session.delete
FileUtils.rm_rf(dir)
