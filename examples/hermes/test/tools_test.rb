# frozen_string_literal: true

# Plain-ruby test harness for the core tool handlers.

require "json"
require "fileutils"
require "tmpdir"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/shell_session"
require_relative "#{ROOT}/process_registry"
require_relative "#{ROOT}/path_guards"
%w[terminal process read_file write_file patch search_files web_search web_extract].each do |t|
  require_relative "#{ROOT}/tools/#{t}"
end

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

def assert_eq(exp, act)
  raise("expected #{exp.inspect}, got #{act.inspect}") unless exp == act
end

def refute(cond, msg = "expected falsy")
  raise msg if cond
end

def fresh_dir
  Dir.mktmpdir("hermes-tools-test")
end

puts "terminal"
test "runs a command and returns output + exit code" do
  t = HermesTools::Terminal.new(session: Hermes::ShellSession.new(workdir: d = fresh_dir, state_dir: d))
  r = JSON.parse(t.call("command" => "echo hello"))
  assert r["output"].include?("hello")
  assert_eq 0, r["exit_code"]
end

test "cwd and exported env persist across calls" do
  d = fresh_dir
  Dir.mkdir(File.join(d, "sub"))
  t = HermesTools::Terminal.new(session: Hermes::ShellSession.new(workdir: d, state_dir: d))
  t.call("command" => "cd sub && export MARKER=42")
  r = JSON.parse(t.call("command" => "pwd && echo $MARKER"))
  assert r["output"].include?("sub"), r["output"]
  assert r["output"].include?("42")
end

test "timeout returns 124" do
  t = HermesTools::Terminal.new(session: Hermes::ShellSession.new(workdir: fresh_dir, state_dir: fresh_dir))
  r = JSON.parse(t.call("command" => "sleep 5", "timeout" => 1))
  assert_eq 124, r["exit_code"]
end

test "background returns a session_id" do
  d = fresh_dir
  t = HermesTools::Terminal.new(session: Hermes::ShellSession.new(workdir: d, state_dir: d),
                                registry: Hermes::ProcessRegistry.new(log_dir: File.join(d, "proc")))
  r = JSON.parse(t.call("command" => "sleep 0.2 && echo done", "background" => true))
  assert r["session_id"]
  assert r["pid"] > 0
end

puts "process"
test "spawn → poll → wait → log lifecycle" do
  d = fresh_dir
  reg = Hermes::ProcessRegistry.new(log_dir: File.join(d, "proc"))
  p_tool = HermesTools::Process.new(registry: reg)
  spawn = JSON.parse(HermesTools::Terminal.new(session: Hermes::ShellSession.new(workdir: d, state_dir: d), registry: reg)
    .call("command" => "echo started; sleep 0.3; echo finished", "background" => true))
  sid = spawn["session_id"]
  poll = JSON.parse(p_tool.call("action" => "poll", "session_id" => sid))
  assert %w[running exited].include?(poll["status"])
  waited = JSON.parse(p_tool.call("action" => "wait", "session_id" => sid, "timeout" => 5))
  assert_eq "exited", waited["status"]
  assert waited["log"].include?("finished")
  list = JSON.parse(p_tool.call("action" => "list"))
  assert list["processes"].any? { |p| p["session_id"] == sid }
end

test "stdin write/submit feeds the process" do
  d = fresh_dir
  reg = Hermes::ProcessRegistry.new(log_dir: File.join(d, "proc"))
  p_tool = HermesTools::Process.new(registry: reg)
  spawn = JSON.parse(HermesTools::Terminal.new(session: Hermes::ShellSession.new(workdir: d, state_dir: d), registry: reg)
    .call("command" => "read line; echo got-$line", "background" => true))
  sid = spawn["session_id"]
  sleep 0.2
  JSON.parse(p_tool.call("action" => "submit", "session_id" => sid, "data" => "hello-stdin\n"))
  waited = JSON.parse(p_tool.call("action" => "wait", "session_id" => sid, "timeout" => 5))
  assert waited["log"].include?("got-hello-stdin"), waited["log"]
end

puts "read_file"
test "paginates with line numbers and a continuation hint" do
  d = fresh_dir
  File.write(File.join(d, "big.txt"), (1..50).map { |i| "line #{i}" }.join("\n"))
  rf = HermesTools::ReadFile.new
  r = JSON.parse(rf.call("path" => File.join(d, "big.txt"), "offset" => 10, "limit" => 5))
  assert r["content"].include?("10|line 10")
  assert r["content"].include?("14|line 14")
  refute r["content"].include?("15|line 15")
  assert r["truncated"]
  assert r["hint"].include?("offset=15")
end

test "guards: device, binary extension, NUL bytes, credentials" do
  rf = HermesTools::ReadFile.new
  assert JSON.parse(rf.call("path" => "/dev/zero"))["error"]
  d = fresh_dir
  File.write(File.join(d, "img.png"), "fake")
  assert JSON.parse(rf.call("path" => File.join(d, "img.png")))["error"].include?("binary")
  File.binwrite(File.join(d, "nulfile"), "a\x00b")
  assert JSON.parse(rf.call("path" => File.join(d, "nulfile")))["error"].include?("NUL")
  assert JSON.parse(rf.call("path" => ".env"))["error"].include?("credential")
end

test "unchanged re-read stubs, then hard-blocks" do
  d = fresh_dir
  File.write(File.join(d, "f.txt"), "content")
  rf = HermesTools::ReadFile.new
  JSON.parse(rf.call("path" => File.join(d, "f.txt")))
  stub = JSON.parse(rf.call("path" => File.join(d, "f.txt")))
  assert stub["dedup"]
  blocked = JSON.parse(rf.call("path" => File.join(d, "f.txt")))
  assert blocked["error"].include?("BLOCKED")
end

test "char budget trims with next_offset" do
  d = fresh_dir
  File.write(File.join(d, "wide.txt"), ("x" * 900 + "\n") * 300)
  rf = HermesTools::ReadFile.new
  r = JSON.parse(rf.call("path" => File.join(d, "wide.txt"), "limit" => 300))
  assert r["truncated_by"] == "bytes"
  assert r["next_offset"] > 1
end

puts "write_file + patch"
test "write_file creates parents; refuses internal display text" do
  d = fresh_dir
  wf = HermesTools::WriteFile.new
  r = JSON.parse(wf.call("path" => File.join(d, "a/b/c.txt"), "content" => "hi"))
  assert r["success"]
  assert_eq "hi", File.read(File.join(d, "a/b/c.txt"))
  bad = JSON.parse(wf.call("path" => File.join(d, "x.txt"), "content" => "1|one\n2|two\n3|three"))
  assert bad["error"].include?("display text")
end

test "patch replace mode: unique, ambiguous, replace_all" do
  d = fresh_dir
  f = File.join(d, "code.rb")
  File.write(f, "foo\nfoo\nbar")
  p = HermesTools::Patch.new
  assert JSON.parse(p.call("mode" => "replace", "path" => f, "old_string" => "foo", "new_string" => "baz"))["error"].include?("matches 2 times")
  assert JSON.parse(p.call("mode" => "replace", "path" => f, "old_string" => "foo", "new_string" => "baz", "replace_all" => true))["success"]
  assert_eq "baz\nbaz\nbar", File.read(f)
end

test "V4A: update with context, add, delete, move, traversal refused" do
  d = fresh_dir
  target = File.join(d, "app.rb")
  File.write(target, "def run\n  fast\nend\n")
  patch_text = <<~PATCH
    *** Begin Patch
    *** Update File: #{target}
    @@ def run @@
     def run
    -  fast
    +  slow
     end
    *** Add File: #{d}/new.txt
    +brand new
    *** End Patch
  PATCH
  p = HermesTools::Patch.new
  r = JSON.parse(p.call("mode" => "patch", "patch" => patch_text))
  assert r["success"], r.inspect
  assert File.read(target).include?("slow")
  assert_eq "brand new\n", File.read(File.join(d, "new.txt"))

  evil = "*** Begin Patch\n*** Update File: ../escape.txt\n@@ x @@\n-a\n+b\n*** End Patch\n"
  assert JSON.parse(p.call("mode" => "patch", "patch" => evil))["error"].include?("traversal")

  mv = "*** Begin Patch\n*** Move File: #{d}/new.txt -> #{d}/moved.txt\n*** End Patch\n"
  assert JSON.parse(p.call("mode" => "patch", "patch" => mv))["success"]
  assert File.exist?(File.join(d, "moved.txt"))

  del = "*** Begin Patch\n*** Delete File: #{d}/moved.txt\n*** End Patch\n"
  assert JSON.parse(p.call("mode" => "patch", "patch" => del))["success"]
  assert !File.exist?(File.join(d, "moved.txt"))
end

puts "search_files"
test "content search with line numbers; files search; modes" do
  d = fresh_dir
  File.write(File.join(d, "one.rb"), "def alpha\nend\n")
  File.write(File.join(d, "two.rb"), "def beta\nend\n")
  sf = HermesTools::SearchFiles.new
  r = JSON.parse(sf.call("pattern" => "alpha", "path" => d))
  assert r["matches"].first.include?("one.rb:1:def alpha")
  files = JSON.parse(sf.call("pattern" => "two", "target" => "files", "path" => d))
  assert files["files"].first.include?("two.rb")
  count = JSON.parse(sf.call("pattern" => "def", "path" => d, "output_mode" => "count"))
  assert count["matches"].any? { |m| m.include?(":1") }
end

puts "web tools"
test "web_search parses duckduckgo html" do
  ws = HermesTools::WebSearch.new
  html = <<~HTML
    <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com">Example</a>
    <a class="result__snippet">An example snippet</a>
  HTML
  results = ws.send(:parse_results, html)
  assert_eq "Example", results.first["title"]
  assert_eq "https://example.com", results.first["url"]
  assert_eq "An example snippet", results.first["snippet"]
end

test "web_extract strips html to text" do
  we = HermesTools::WebExtract.new
  text = we.send(:html_to_text, "<html><style>x{}</style><body><h1>Title</h1><p>Body<br>break</p></body></html>")
  assert text.include?("Title")
  assert text.include?("Body\nbreak")
  refute text.include?("x{}")
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
