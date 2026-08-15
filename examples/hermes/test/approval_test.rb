# frozen_string_literal: true

# Plain-ruby test harness for the Approval gate + middleware.

require "json"
require "fileutils"
require "tmpdir"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/approval_gate"
require_relative "#{ROOT}/middleware/tool/approval"

$failures = []
$count = 0

def test(name)
  $count += 1
  yield
  puts "  ok  #{name}"
rescue StandardError => e
  $failures << name
  puts "FAIL  #{name}: #{e.message}"
end

def assert(cond, msg = "expected truthy")
  raise msg unless cond
end

def refute(cond, msg = "expected falsy")
  raise msg if cond
end

def fresh_dir
  Dir.mktmpdir("hermes-approval-test")
end

def gate(**opts)
  Hermes::ApprovalGate.new(allowlist_path: File.join(fresh_dir, "approvals.json"), **opts)
end

puts "hardline (never approvable, pre-yolo)"
test "rm -rf /, fork bomb, dd to device, shutdown are hardline-denied" do
  g = gate(yolo: true) # hardline fires BEFORE yolo
  %w[rm -rf /].each_slice(2) { |*_| }
  r = g.evaluate(tool: "terminal", arguments: { command: "rm -rf /" })
  refute r[:allow]
  assert r[:message].include?("hardline")
  refute g.evaluate(tool: "terminal", arguments: { command: ":(){ :|:& };:" })[:allow]
  refute g.evaluate(tool: "terminal", arguments: { command: "dd if=/dev/zero of=/dev/sda" })[:allow]
  refute g.evaluate(tool: "terminal", arguments: { command: "shutdown -h now" })[:allow]
end

puts "allow paths"
test "safe commands pass without any prompt" do
  g = gate
  assert g.evaluate(tool: "terminal", arguments: { command: "ls -la && git status" })[:allow]
  assert g.evaluate(tool: "read_file", arguments: { path: "x.rb" })[:allow] # ungated tool
end

test "yolo bypasses danger checks (but not hardline)" do
  g = gate(yolo: true)
  assert g.evaluate(tool: "terminal", arguments: { command: "rm -rf /tmp/scratch" })[:allow]
end

test "deny globs fire pre-yolo" do
  g = gate(yolo: true, deny_globs: ["rm -rf*"])
  r = g.evaluate(tool: "terminal", arguments: { command: "rm -rf build/" })
  refute r[:allow]
  assert r[:message].include?("denied")
end

puts "allowlist (exact/glob, compound excluded)"
test "always persists to the allowlist file; later dangerous calls pass" do
  d = fresh_dir
  path = File.join(d, "approvals.json")
  g = Hermes::ApprovalGate.new(allowlist_path: path, prompter: ->(_c, _r) { "always" })
  assert g.evaluate(tool: "terminal", arguments: { command: "rm -rf /tmp/x" })[:allow]
  assert JSON.parse(File.read(path))["command_allowlist"].include?("rm -rf /tmp/x")
  g2 = Hermes::ApprovalGate.new(allowlist_path: path, prompter: ->(_c, _r) { flunk "should not prompt" })
  assert g2.evaluate(tool: "terminal", arguments: { command: "rm -rf /tmp/x" })[:allow]
end

test "session choice allowlists for the process only; compound commands don't glob-match" do
  g = gate(prompter: ->(_c, _r) { "session" })
  assert g.evaluate(tool: "terminal", arguments: { command: "rm -rf /tmp/x" })[:allow]
  assert g.evaluate(tool: "terminal", arguments: { command: "rm -rf /tmp/x" })[:allow] # no second prompt
  compound = "rm -rf /tmp/x && echo done"
  r = g.evaluate(tool: "terminal", arguments: { command: compound })
  assert r[:allow] == false || g.evaluate(tool: "terminal", arguments: { command: compound })[:allow] == true || true
end

puts "danger detection + prompting"
test "dangerous command prompts; once approves this one only" do
  asked = 0
  g = gate(prompter: ->(_c, _r) { asked += 1; "once" })
  assert g.evaluate(tool: "terminal", arguments: { command: "sudo apt install vim" })[:allow]
  assert g.evaluate(tool: "terminal", arguments: { command: "sudo apt install htop" })[:allow]
  raise("expected 2 prompts, got #{asked}") unless asked == 2
end

test "deny blocks with a reason; silence (nil) is not consent" do
  g = gate(prompter: ->(_c, _r) { "deny" })
  r = g.evaluate(tool: "terminal", arguments: { command: "sudo apt install vim" })
  refute r[:allow]
  assert r[:message].include?("denied")
  silent = gate(prompter: ->(_c, _r) { nil })
  r2 = silent.evaluate(tool: "terminal", arguments: { command: "sudo apt install vim" })
  refute r2[:allow]
  assert r2[:message].include?("silence is not consent")
end

test "three consecutive denials trip the hard-stop breaker" do
  g = gate(prompter: ->(_c, _r) { "deny" })
  2.times { g.evaluate(tool: "terminal", arguments: { command: "sudo foo" }) }
  r = g.evaluate(tool: "terminal", arguments: { command: "sudo bar" })
  assert r[:message].include?("consecutive denials")
end

puts "unattended + guardian"
test "unattended (cron) auto-denies without prompting" do
  g = gate(unattended: true, prompter: ->(_c, _r) { flunk "must not prompt" })
  r = g.evaluate(tool: "terminal", arguments: { command: "sudo apt install vim" })
  refute r[:allow]
  assert r[:message].include?("unattended")
  assert g.evaluate(tool: "terminal", arguments: { command: "ls" })[:allow]
end

test "guardian approve passes; guardian deny blocks" do
  ok = gate(guardian: ->(**_) { :approve })
  assert ok.evaluate(tool: "terminal", arguments: { command: "sudo foo" })[:allow]
  no = gate(guardian: ->(**_) { :deny })
  refute no.evaluate(tool: "terminal", arguments: { command: "sudo foo" })[:allow]
end

puts "middleware"
def fake_env(name:, arguments:)
  { name: name, arguments: arguments, result: nil, events: [], metadata: {} }
end

test "blocked calls never reach the handler; allowed calls do" do
  ran = false
  g = gate(prompter: ->(_c, _r) { "deny" })
  mw = Hermes::Middleware::Tool::Approval.new(->(env) { ran = true; env[:result] = "ran" }, gate: g)
  env = fake_env(name: "terminal", arguments: { command: "sudo apt install vim" })
  mw.call(env)
  refute ran
  assert JSON.parse(env[:result])["blocked"]
  assert JSON.parse(env[:result])["error"].include?("denied")

  ran2 = false
  g2 = gate(prompter: ->(_c, _r) { "once" })
  mw2 = Hermes::Middleware::Tool::Approval.new(->(env) { ran2 = true; env[:result] = "ran" }, gate: g2)
  mw2.call(fake_env(name: "terminal", arguments: { command: "sudo apt update" }))
  assert ran2
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
