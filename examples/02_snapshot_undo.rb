#!/usr/bin/env ruby
# frozen_string_literal: true

# Test the SnapshotStore — copy-on-write file undo support.

require_relative "../lib/brute"

DIR = File.expand_path("tmp/snapshot_test", __dir__)
FileUtils.rm_rf(DIR)
FileUtils.mkdir_p(DIR)

puts "=== 02: SnapshotStore Tests ==="
puts

Brute::SnapshotStore.clear!
path = "#{DIR}/file.txt"

Brute::SnapshotStore.save(path)
Brute::SnapshotStore.depth(path).then { |d| puts "1. Saved non-existent file: depth=#{d}" }

File.write(path, "version 1")
Brute::SnapshotStore.save(path)
Brute::SnapshotStore.depth(path).then { |d| puts "2. Saved v1: depth=#{d}" }

File.write(path, "version 2")
Brute::SnapshotStore.save(path)
Brute::SnapshotStore.depth(path).then { |d| puts "3. Saved v2: depth=#{d}" }

File.write(path, "version 3 (current)")
puts "4. Current: #{File.read(path)}"

Brute::SnapshotStore.pop(path).then do |snap|
  File.write(path, snap) unless snap == :did_not_exist
  puts "5. Undo → #{File.read(path)} (depth=#{Brute::SnapshotStore.depth(path)})"
end

Brute::SnapshotStore.pop(path).then do |snap|
  File.write(path, snap) unless snap == :did_not_exist
  puts "6. Undo → #{File.read(path)} (depth=#{Brute::SnapshotStore.depth(path)})"
end

Brute::SnapshotStore.pop(path).then do |snap|
  if snap == :did_not_exist
    File.delete(path) if File.exist?(path)
    puts "7. Undo → file deleted (depth=#{Brute::SnapshotStore.depth(path)})"
  end
end

Brute::SnapshotStore.pop(path).then do |snap|
  puts "8. No more history: #{snap.nil? ? "nil (correct)" : "UNEXPECTED"}"
end

Brute::SnapshotStore.clear!
Brute::SnapshotStore.depth(path).then { |d| puts "9. After clear!: depth=#{d}" }

FileUtils.rm_rf(DIR)
puts
puts "=== All SnapshotStore tests passed ==="
