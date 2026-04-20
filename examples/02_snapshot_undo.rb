#!/usr/bin/env ruby
# frozen_string_literal: true

# Copy-on-write undo: snapshot file state before mutations, pop to restore.

require_relative "../lib/brute"

dir = File.expand_path("tmp/snapshot_example", __dir__)
FileUtils.mkdir_p(dir)
path = "#{dir}/file.txt"

Brute::SnapshotStore.clear!

# Snapshot before each write
File.write(path, "version 1")
Brute::SnapshotStore.save(path)

File.write(path, "version 2")
Brute::SnapshotStore.save(path)

File.write(path, "version 3")

# Pop back through history
Brute::SnapshotStore.pop(path).then { |snap| File.write(path, snap) } # -> version 2
Brute::SnapshotStore.pop(path).then { |snap| File.write(path, snap) } # -> version 1

puts File.read(path)

FileUtils.rm_rf(dir)
