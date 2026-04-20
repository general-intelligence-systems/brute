#!/usr/bin/env ruby
# frozen_string_literal: true

# Filesystem tools: write, read, patch, search, undo -- no API key needed.

require_relative "../lib/brute"

dir = File.expand_path("tmp/tools_example", __dir__)
FileUtils.mkdir_p(dir)
path = "#{dir}/greeting.txt"

# Write a file
Brute::Tools::FSWrite.new.call(file_path: path, content: "Hello, world!\nLine 2\n")

# Read it back
content = Brute::Tools::FSRead.new.call(file_path: path)

# Patch it
Brute::Tools::FSPatch.new.call(file_path: path, old_string: "world", new_string: "Brute")

# Search for a pattern
results = Brute::Tools::FSSearch.new.call(pattern: "Brute", path: dir)

# Undo the patch
Brute::Tools::FSUndo.new.call(path: path)

# Run a shell command
output = Brute::Tools::Shell.new.call(command: "cat #{path}")

puts output[:stdout]

FileUtils.rm_rf(dir)
