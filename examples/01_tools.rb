#!/usr/bin/env ruby
# frozen_string_literal: true

# Test all filesystem and utility tools without needing an API key.

require_relative "../lib/brute"

DIR = File.expand_path("tmp/tools_test", __dir__)
FileUtils.rm_rf(DIR)
FileUtils.mkdir_p(DIR)

$pass = 0

def test(name)
  print "  #{name}... "
  yield.then do |ok|
    puts ok ? "PASS" : "FAIL"
    $pass += 1 if ok
  end
rescue => e
  puts "ERROR: #{e.message}"
end

puts "=== 01: Tool Tests ==="
puts

# --- FSWrite ---
puts "[FSWrite]"
Brute::Tools::FSWrite.new.call(file_path: "#{DIR}/hello.txt", content: "Hello, Brute!\nLine 2\nLine 3\n").then do |r|
  test("creates file") { r[:success] && File.exist?("#{DIR}/hello.txt") }
  test("correct bytes") { r[:bytes] == 28 }
end

# --- FSRead ---
puts "[FSRead]"
Brute::Tools::FSRead.new.call(file_path: "#{DIR}/hello.txt").then do |r|
  test("reads full file") { r[:content].include?("Hello, Brute!") && r[:total_lines] == 3 }
end

Brute::Tools::FSRead.new.call(file_path: "#{DIR}/hello.txt", start_line: 2, end_line: 2).then do |r|
  test("reads line range") { r[:content].include?("Line 2") && !r[:content].include?("Hello") }
end

test("error on missing file") { (Brute::Tools::FSRead.new.call(file_path: "#{DIR}/nope.txt") rescue $!).is_a?(RuntimeError) }

# --- FSPatch ---
puts "[FSPatch]"
Brute::Tools::FSPatch.new.call(file_path: "#{DIR}/hello.txt", old_string: "Hello, Brute!", new_string: "Hi, Brute!").then do |r|
  test("patches content") { r[:success] && File.read("#{DIR}/hello.txt").include?("Hi, Brute!") }
end

test("error on missing string") { (Brute::Tools::FSPatch.new.call(file_path: "#{DIR}/hello.txt", old_string: "NOPE", new_string: "x") rescue $!).is_a?(RuntimeError) }

# --- FSSearch ---
puts "[FSSearch]"
Brute::Tools::FSSearch.new.call(pattern: "Brute", path: DIR).then do |r|
  test("finds pattern") { r[:results].include?("Brute") }
end

Brute::Tools::FSSearch.new.call(pattern: "ZZZNOMATCH999", path: DIR).then do |r|
  test("no match returns empty") { r[:results].strip.empty? || r[:exit_code] == 1 }
end

# --- FSRemove ---
puts "[FSRemove]"
File.write("#{DIR}/to_delete.txt", "bye")
Brute::Tools::FSRemove.new.call(path: "#{DIR}/to_delete.txt").then do |r|
  test("removes file") { r[:success] && !File.exist?("#{DIR}/to_delete.txt") }
end

# --- FSUndo ---
puts "[FSUndo]"
File.read("#{DIR}/hello.txt").then do |original|
  Brute::Tools::FSWrite.new.call(file_path: "#{DIR}/hello.txt", content: "OVERWRITTEN")
  test("file was overwritten") { File.read("#{DIR}/hello.txt") == "OVERWRITTEN" }

  Brute::Tools::FSUndo.new.call(path: "#{DIR}/hello.txt").then do |r|
    test("undo restores") { r[:success] && File.read("#{DIR}/hello.txt") == original }
  end
end

# --- Shell ---
puts "[Shell]"
Brute::Tools::Shell.new.call(command: "echo hello_from_shell").then do |r|
  test("runs command") { r[:stdout].strip == "hello_from_shell" && r[:exit_code] == 0 }
end

Brute::Tools::Shell.new.call(command: "exit 42").then do |r|
  test("captures exit code") { r[:exit_code] == 42 }
end

Brute::Tools::Shell.new.call(command: "ls", cwd: DIR).then do |r|
  test("respects cwd") { r[:stdout].include?("hello.txt") }
end

# --- NetFetch ---
puts "[NetFetch]"
Brute::Tools::NetFetch.new.call(url: "https://httpbin.org/get").then do |r|
  test("fetches URL") { r[:status] == 200 && r[:body].include?("httpbin") }
end

# --- TodoWrite + TodoRead ---
puts "[TodoWrite / TodoRead]"
Brute::TodoStore.clear!
Brute::Tools::TodoWrite.new.call(todos: [
  { id: "1", content: "First task", status: "pending" },
  { id: "2", content: "Second task", status: "in_progress" },
])
Brute::Tools::TodoRead.new.call.then do |r|
  test("writes and reads todos") { r[:todos].size == 2 && r[:todos][1][:status] == "in_progress" }
end

# --- Delegate ---
puts "[Delegate]"
test("delegate class exists") { Brute::Tools::Delegate.is_a?(Class) }

# --- Cleanup ---
FileUtils.rm_rf(DIR)

puts
puts "=== #{$pass} passed ==="
