# frozen_string_literal: true

# Plain-ruby test harness for the six core tools (read_file, write_file,
# edit_file, append_file, list_dir, exec) — runs anywhere, no gems beyond
# brute itself. Every test asserts upstream picoclaw behavior byte-for-byte
# where observable (see FEATURES.md Part 1 and the tool header comments).

require "fileutils"
require "tmpdir"
require "json"

# The local checkout shadows the gem (main.rb needs Brute::PromptTemplate,
# which brute 3.2.2 doesn't ship yet — see README#Dependencies).
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/tools/fs_sandbox"
require_relative "#{ROOT}/tools/diff_result"
require_relative "#{ROOT}/tools/exec_session"
require_relative "#{ROOT}/tools/read_file"
require_relative "#{ROOT}/tools/write_file"
require_relative "#{ROOT}/tools/edit_file"
require_relative "#{ROOT}/tools/append_file"
require_relative "#{ROOT}/tools/list_dir"
require_relative "#{ROOT}/tools/exec"

$failures = []
$count = 0

def test(name)
  $count += 1
  yield
  puts "  ok  #{name}"
rescue StandardError, ScriptError => e
  $failures << [name, e]
  puts "FAIL  #{name}: #{e.class}: #{e.message}"
  puts e.backtrace.first(5).map { |l| "      #{l}" }
end

def assert(cond, msg = "expected truthy")
  raise msg unless cond
end
def assert_equal(exp, act)
  raise("expected #{exp.inspect}, got #{act.inspect}") unless exp == act
end

def assert_includes(hay, needle)
  raise("expected to include #{needle.inspect}:\n#{hay}") unless hay.include?(needle)
end

def refute_includes(hay, needle)
  raise("expected NOT to include #{needle.inspect}:\n#{hay}") if hay.include?(needle)
end

def assert_nil(val)
  raise("expected nil, got #{val.inspect}") unless val.nil?
end

def assert_raises(klass)
  yield
  raise("expected #{klass} to be raised, nothing was")
rescue klass => e
  e
end

def workspace
  Dir.mktmpdir("picoclaw-tools-test")
end

def write_raw(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, content)
end

# --- read_file: bytes mode ---------------------------------------------------

test "read_file bytes: small file, header + END OF FILE" do
  w = workspace
  write_raw("#{w}/t.txt", "hello\nworld\n")
  out = ReadFile.new(workspace: w).call("path" => "t.txt")
  assert_includes out, "[file: t.txt | total: 12 bytes | read: bytes 0-11]"
  assert_includes out, "[END OF FILE - no further content.]"
  assert_includes out, "\n\nhello\nworld\n"
  refute_includes out, w # basename only, no workspace leak
ensure
  FileUtils.rm_rf(w)
end

test "read_file bytes: pagination, length+1 probe (no false TRUNCATED on last page)" do
  w = workspace
  write_raw("#{w}/big.txt", "0123456789" * 100) # 1000 bytes
  tool = ReadFile.new(workspace: w)
  page1 = tool.call("path" => "big.txt", "length" => 100)
  assert_includes page1, "read: bytes 0-99"
  assert_includes page1, "Call read_file again with offset=100 to continue."
  page2 = tool.call("path" => "big.txt", "offset" => 900, "length" => 100)
  assert_includes page2, "read: bytes 900-999"
  assert_includes page2, "[END OF FILE - no further content.]" # probe proved EOF
  eof = tool.call("path" => "big.txt", "offset" => 1000)
  assert_equal "[END OF FILE - no content at this offset]", eof
ensure
  FileUtils.rm_rf(w)
end

test "read_file bytes: length silently capped at max_size" do
  w = workspace
  write_raw("#{w}/big.txt", "x" * 500)
  out = ReadFile.new(workspace: w, max_size: 100).call("path" => "big.txt", "length" => 500)
  assert_includes out, "read: bytes 0-99"
  assert_includes out, "TRUNCATED"
ensure
  FileUtils.rm_rf(w)
end

test "read_file bytes: arg validation" do
  w = workspace
  write_raw("#{w}/t.txt", "data")
  tool = ReadFile.new(workspace: w)
  assert_equal "path is required", tool.call({})
  assert_equal "offset must be >= 0", tool.call("path" => "t.txt", "offset" => -1)
  assert_equal "length must be > 0", tool.call("path" => "t.txt", "length" => 0)
  assert_equal "length must be an integer, got float 1.5", tool.call("path" => "t.txt", "length" => 1.5)
  assert_includes tool.call("path" => "t.txt", "length" => "2"), "read: bytes 0-1" # numeric string ok
  assert_includes tool.call("path" => "missing.txt"), "failed to open file: file not found:"
ensure
  FileUtils.rm_rf(w)
end

test "read_file: lexical escape and symlink escape denied" do
  w = workspace
  outside = workspace
  write_raw("#{outside}/secret.txt", "top secret")
  File.symlink("#{outside}/secret.txt", "#{w}/link.txt")
  tool = ReadFile.new(workspace: w)
  assert_equal "path escapes workspace: ../secret.txt", tool.call("path" => "../secret.txt")
  symlinked = tool.call("path" => "link.txt")
  assert_includes symlinked, "access denied"
  refute_includes symlinked, "top secret"
ensure
  FileUtils.rm_rf(w)
  FileUtils.rm_rf(outside)
end

test "read_file: allow_read_paths whitelist (regex + anchored-literal prefix form)" do
  w = workspace
  outside = workspace
  write_raw("#{outside}/docs/a.txt", "whitelisted")
  regex_tool = ReadFile.new(workspace: w, allow_paths: [Regexp.new(Regexp.escape("#{outside}/docs"))])
  assert_includes regex_tool.call("path" => "#{outside}/docs/a.txt"), "whitelisted"
  prefix_tool = ReadFile.new(workspace: w, allow_paths: [Regexp.new("^#{Regexp.escape(outside)}(?:/|$)")])
  assert_includes prefix_tool.call("path" => "#{outside}/docs/a.txt"), "whitelisted"
  denied = ReadFile.new(workspace: w)
  assert_includes denied.call("path" => "#{outside}/docs/a.txt"), "path escapes workspace:"
ensure
  FileUtils.rm_rf(w)
  FileUtils.rm_rf(outside)
end

# --- read_file: lines mode -----------------------------------------------------

test "read_file lines: numbering, start_line skip, max_lines + PARTIAL resume hint" do
  w = workspace
  write_raw("#{w}/l.txt", "a\nb\nc\nd\n")
  tool = ReadFile.new(workspace: w, mode: "lines")
  full = tool.call("path" => "l.txt")
  assert_includes full, "[file: l.txt | read: lines 1-4 (1-indexed)"
  assert_includes full, "1|a\n2|b\n3|c\n4|d\n"
  assert_includes full, "[END OF FILE - no further content.]"
  partial = tool.call("path" => "l.txt", "start_line" => 2, "max_lines" => 1)
  assert_includes partial, "read: lines 2-2"
  assert_includes partial, "2|b\n"
  assert_includes partial, "[PARTIAL - more content remains. Call read_file again with start_line=3 and max_lines=1 to continue.]"
  past = tool.call("path" => "l.txt", "start_line" => 99)
  assert_equal "[END OF FILE - no content at or after start_line=99]", past
ensure
  FileUtils.rm_rf(w)
end

test "read_file lines: byte budget — mid-line cut and between-lines stop" do
  w = workspace
  write_raw("#{w}/long.txt", ("x" * 100) + "\nrest\n")
  mid = ReadFile.new(workspace: w, mode: "lines", max_size: 30).call("path" => "long.txt")
  assert_includes mid, "exceeded the 30 byte read budget and was cut mid-line.]"
  assert_includes mid, "1|#{"x" * 28}"

  write_raw("#{w}/many.txt", "aaaa\n" * 10) # 7 bytes per numbered line ("1|aaaa\n")
  stop = ReadFile.new(workspace: w, mode: "lines", max_size: 14).call("path" => "many.txt")
  assert_includes stop, "read: lines 1-2"
  assert_includes stop, "[TRUNCATED - byte budget reached. Call read_file again with start_line=3 to continue at the next line.]"
ensure
  FileUtils.rm_rf(w)
end

test "read_file lines: rejects offset-style args, binary files, directories" do
  w = workspace
  write_raw("#{w}/l.txt", "a\n")
  write_raw("#{w}/img.png", "\x89PNG\r\n\x1A\n".b + "\x00\x01\x02".b * 20)
  tool = ReadFile.new(workspace: w, mode: "lines")
  assert_equal "offset is not supported in line mode; use start_line", tool.call("path" => "l.txt", "offset" => 1)
  assert_equal "length is not supported in line mode; use max_lines", tool.call("path" => "l.txt", "length" => 1)
  assert_equal "limit is not supported in line mode; use max_lines", tool.call("path" => "l.txt", "limit" => 1)
  assert_equal "file appears to be binary; switch read_file mode to 'bytes' for byte-based inspection",
               tool.call("path" => "img.png")
  assert_equal "failed to open file: path is a directory: .", tool.call("path" => ".")
ensure
  FileUtils.rm_rf(w)
end

# --- write_file -----------------------------------------------------------------

test "write_file: create (0600, parents), refuse-overwrite copy, overwrite=true, atomicity" do
  w = workspace
  tool = WriteFile.new(workspace: w)
  assert_equal "File written: sub/dir/new.txt", tool.call("path" => "sub/dir/new.txt", "content" => "v1\n")
  assert_equal "v1\n", File.binread("#{w}/sub/dir/new.txt")
  assert_equal 0o600, File.stat("#{w}/sub/dir/new.txt").mode & 0o777

  refuse = tool.call("path" => "sub/dir/new.txt", "content" => "v2")
  assert_includes refuse, "file: sub/dir/new.txt already exists."
  assert_includes refuse, "use append_file or edit_file."
  assert_equal "v1\n", File.binread("#{w}/sub/dir/new.txt")

  assert_equal "File written: sub/dir/new.txt", tool.call("path" => "sub/dir/new.txt", "content" => "v2", "overwrite" => true)
  assert_equal "v2", File.binread("#{w}/sub/dir/new.txt")

  # "true" (string) is NOT a boolean true upstream — overwrite stays false.
  refuse2 = tool.call("path" => "sub/dir/new.txt", "content" => "v3", "overwrite" => "true")
  assert_includes refuse2, "already exists"

  leftovers = Dir.glob("#{w}/**/.tmp-*")
  assert_equal [], leftovers
ensure
  FileUtils.rm_rf(w)
end

test "write_file: escape blocked, allow_write_paths whitelisted" do
  w = workspace
  outside = workspace
  assert_equal "path escapes workspace: ../x.txt", WriteFile.new(workspace: w).call("path" => "../x.txt", "content" => "x")
  allowed = WriteFile.new(workspace: w, allow_paths: [Regexp.new(Regexp.escape(outside))])
  assert_equal "File written: #{outside}/ok.txt", allowed.call("path" => "#{outside}/ok.txt", "content" => "x")
  assert_equal "x", File.binread("#{outside}/ok.txt")
ensure
  FileUtils.rm_rf(w)
  FileUtils.rm_rf(outside)
end

# --- edit_file -------------------------------------------------------------------

test "edit_file: single-occurrence replace, not-found, multiple, no-change" do
  w = workspace
  write_raw("#{w}/e.txt", "alpha\nbeta\ngamma\n")
  tool = EditFile.new(workspace: w)
  assert_equal "File edited: e.txt", tool.call("path" => "e.txt", "old_text" => "beta", "new_text" => "BETA")
  assert_equal "alpha\nBETA\ngamma\n", File.binread("#{w}/e.txt")
  assert_equal "old_text not found in file. Make sure it matches exactly",
               tool.call("path" => "e.txt", "old_text" => "nope", "new_text" => "x")
  write_raw("#{w}/m.txt", "dup\ndup\n")
  assert_equal "old_text appears 2 times. Please provide more context to make it unique",
               tool.call("path" => "m.txt", "old_text" => "dup", "new_text" => "x")
  assert_equal "File edited: e.txt\n(no content change)",
               tool.call("path" => "e.txt", "old_text" => "alpha", "new_text" => "alpha")
  assert_equal "path is required", tool.call({})
ensure
  FileUtils.rm_rf(w)
end

test "edit_file: diff size guards (>64KB skipped; >16KB hunk notes truncation)" do
  w = workspace
  tool = EditFile.new(workspace: w)
  big = "z" * 70_000
  write_raw("#{w}/big.txt", big)
  skipped = tool.call("path" => "big.txt", "old_text" => big, "new_text" => "small")
  assert_includes skipped, "[diff preview skipped: file too large for inline preview]"
  assert_equal "small", File.binread("#{w}/big.txt")

  write_raw("#{w}/hunk.txt", "a" * 20_000)
  truncated = tool.call("path" => "hunk.txt", "old_text" => "a" * 20_000, "new_text" => "b" * 20_000)
  assert_equal "File edited: hunk.txt\n[diff preview truncated; call read_file for the full edited contents]", truncated
ensure
  FileUtils.rm_rf(w)
end

test "DiffResult: exact unified diff (single hunk, EOF-newline marker)" do
  diff = DiffResult.build_unified_diff("f", "a\nb\nc\n", "a\nX\nc\n")
  assert_equal <<~DIFF.chomp, diff
    --- a/f
    +++ b/f
    @@ -1,3 +1,3 @@
     a
    -b
    +X
     c
  DIFF
  eof = DiffResult.build_unified_diff("f", "a", "b")
  assert_includes eof, "\\ No newline at end of file"
  assert_equal "(no content change)", DiffResult.build_unified_diff("f", "same\n", "same\n")
  assert_equal "file", DiffResult.display_path("/")
  assert_equal "tmp/x", DiffResult.display_path("/tmp/x")
end

# --- append_file ------------------------------------------------------------------

test "append_file: appends, creates when missing, blocks escape" do
  w = workspace
  tool = AppendFile.new(workspace: w)
  write_raw("#{w}/a.txt", "one\n")
  assert_equal "Appended to a.txt", tool.call("path" => "a.txt", "content" => "two\n")
  assert_equal "one\ntwo\n", File.binread("#{w}/a.txt")
  assert_equal "Appended to fresh.txt", tool.call("path" => "fresh.txt", "content" => "new")
  assert_equal "new", File.binread("#{w}/fresh.txt")
  assert_equal "path escapes workspace: ../x", tool.call("path" => "../x", "content" => "x")
ensure
  FileUtils.rm_rf(w)
end

# --- list_dir ---------------------------------------------------------------------

test "list_dir: DIR/FILE format, sorted, symlink-to-dir is FILE, '.' fallback, errors" do
  w = workspace
  write_raw("#{w}/b.txt", "x")
  FileUtils.mkdir_p("#{w}/adir")
  write_raw("#{w}/adir/inner.txt", "x")
  File.symlink("#{w}/adir", "#{w}/dirlink")
  tool = ListDir.new(workspace: w)
  assert_equal "DIR:  adir\nFILE: b.txt\nFILE: dirlink\n", tool.call("path" => ".")
  assert_equal tool.call("path" => "."), tool.call({}) # missing arg falls back to "."
  assert_includes tool.call("path" => "nope"), "failed to read directory:"
  assert_includes tool.call("path" => "../"), "failed to read directory: path escapes workspace"
ensure
  FileUtils.rm_rf(w)
end

# --- exec: dispatch + sync run ------------------------------------------------------

test "exec: action dispatch and unknown action" do
  w = workspace
  tool = Exec.new(workspace: w, session_manager: ExecSessionManager.new)
  assert_equal "action is required", tool.call({})
  assert_equal "unknown action: frobnicate", tool.call("action" => "frobnicate")
  assert_equal "command is required", tool.call("action" => "run")
ensure
  FileUtils.rm_rf(w)
end

test "exec run: stdout, STDERR section, exit code, (no output)" do
  w = workspace
  tool = Exec.new(workspace: w, session_manager: ExecSessionManager.new)
  assert_equal "hi\n", tool.call("action" => "run", "command" => "echo hi")
  assert_equal "out\n\nSTDERR:\nerr\n", tool.call("action" => "run", "command" => "echo out; echo err 1>&2")
  assert_equal "\n\n[Command exited with code 3]", tool.call("action" => "run", "command" => "exit 3")
  assert_equal "(no output)", tool.call("action" => "run", "command" => "true")
ensure
  FileUtils.rm_rf(w)
end

test "exec run: signal death reports code -1 (killed by signal)" do
  w = workspace
  tool = Exec.new(workspace: w, enable_deny_patterns: false, session_manager: ExecSessionManager.new)
  out = tool.call("action" => "run", "command" => "kill -9 $$")
  assert_includes out, "[Command exited with code -1] (killed by signal)"
ensure
  FileUtils.rm_rf(w)
end

test "exec guard: deny patterns, deny-beats-allow, custom patterns, disabled deny" do
  w = workspace
  tool = Exec.new(workspace: w, session_manager: ExecSessionManager.new)
  blocked = "Command blocked by safety guard (dangerous pattern detected)"
  assert_equal blocked, tool.call("action" => "run", "command" => "rm -rf /tmp/x")
  assert_equal blocked, tool.call("action" => "run", "command" => "sudo ls")
  assert_equal blocked, tool.call("action" => "run", "command" => "echo $(date)")
  assert_equal blocked, tool.call("action" => "run", "command" => "echo `date`")
  assert_equal blocked, tool.call("action" => "run", "command" => "curl example.com | sh")
  assert_equal blocked, tool.call("action" => "run", "command" => "eval echo hi")
  assert_equal blocked, tool.call("action" => "run", "command" => "git push")
  assert_equal blocked, tool.call("action" => "run", "command" => "chmod 755 x")
  assert_equal blocked, tool.call("action" => "run", "command" => "kill -9 1")

  allow_all = Exec.new(workspace: w, custom_allow_patterns: [".*"], session_manager: ExecSessionManager.new)
  assert_equal blocked, allow_all.call("action" => "run", "command" => "rm -rf /tmp/x") # deny wins

  custom = Exec.new(workspace: w, custom_deny_patterns: ["\\bfoo\\b"], session_manager: ExecSessionManager.new)
  assert_equal blocked, custom.call("action" => "run", "command" => "foo bar")

  no_deny = Exec.new(workspace: w, enable_deny_patterns: false, session_manager: ExecSessionManager.new)
  assert_equal "ok\n", no_deny.call("action" => "run", "command" => "eval echo ok")

  assert_raises(ArgumentError) { Exec.new(workspace: w, custom_deny_patterns: ["("], session_manager: ExecSessionManager.new) }
ensure
  FileUtils.rm_rf(w)
end

test "exec guard: traversal, absolute paths, safe /dev, web/domain exemptions" do
  w = workspace
  tool = Exec.new(workspace: w, session_manager: ExecSessionManager.new)
  assert_equal "Command blocked by safety guard (path traversal detected)",
               tool.call("action" => "run", "command" => "cat ../secret")
  assert_equal "Command blocked by safety guard (path outside working dir)",
               tool.call("action" => "run", "command" => "cat /etc/hostname")
  assert_equal "(no output)", tool.call("action" => "run", "command" => "echo x > /dev/null")
  assert_equal "https://example.com/x\n", tool.call("action" => "run", "command" => "echo https://example.com/x")
  assert_equal "wttr.in/Berlin\n", tool.call("action" => "run", "command" => "echo wttr.in/Berlin")
  FileUtils.mkdir_p("#{w}/foo.bar") # a domain-like LOCAL entry must be validated, not skipped
  out = tool.call("action" => "run", "command" => "cat foo.bar/nope")
  refute_includes out, "Command blocked"
  assert_includes out, "STDERR" # cat: no such file — ran, failed, was not blocked
ensure
  FileUtils.rm_rf(w)
end

test "exec guard: cwd validation" do
  w = workspace
  FileUtils.mkdir_p("#{w}/sub")
  tool = Exec.new(workspace: w, session_manager: ExecSessionManager.new)
  assert_equal "Command blocked by safety guard (access denied: path is outside the workspace)",
               tool.call("action" => "run", "command" => "ls", "cwd" => "/etc")
  out = tool.call("action" => "run", "command" => "pwd", "cwd" => "sub")
  assert_includes out, "sub"
ensure
  FileUtils.rm_rf(w)
end

test "exec run: timeout (Go duration format), partial output, timeout PARAM is ignored" do
  w = workspace
  tool = Exec.new(workspace: w, timeout: 1, session_manager: ExecSessionManager.new)
  out = tool.call("action" => "run", "command" => "echo before; sleep 5; echo after", "timeout" => 99)
  assert_includes out, "Command timed out after 1s"
  assert_includes out, "Partial output before timeout:\nbefore\n"
  refute_includes out, "after\n"
ensure
  FileUtils.rm_rf(w)
end

test "exec run: 10000-char truncation" do
  w = workspace
  tool = Exec.new(workspace: w, session_manager: ExecSessionManager.new)
  out = tool.call("action" => "run", "command" => "seq 1 5000")
  assert_includes out, "\n... (truncated, "
  assert_includes out, "more chars)"
ensure
  FileUtils.rm_rf(w)
end

test "exec: allow_remote gate" do
  w = workspace
  tool = Exec.new(workspace: w, allow_remote: false, session_manager: ExecSessionManager.new)
  assert_equal "exec is restricted to internal channels", tool.call("action" => "run", "command" => "true")
  assert_equal "exec is restricted to internal channels", tool.call("action" => "run", "command" => "true", "__channel" => "telegram")
  assert_equal "(no output)", tool.call("action" => "run", "command" => "true", "__channel" => "cli")
ensure
  FileUtils.rm_rf(w)
end

# --- exec: background sessions --------------------------------------------------------

test "exec background: run/poll/read(destructive)/list/kill" do
  w = workspace
  mgr = ExecSessionManager.new
  tool = Exec.new(workspace: w, session_manager: mgr)
  resp = JSON.parse(tool.call("action" => "run", "command" => "sleep 0.2; echo bg-done", "background" => "true"))
  id = resp["sessionId"]
  assert_equal "running", resp["status"]
  assert_equal 8, id.length

  listing = JSON.parse(tool.call("action" => "list"))
  assert_equal id, listing["sessions"].find { |s| s["id"] == id }["id"]
  assert_equal "sleep 0.2; echo bg-done", listing["sessions"].find { |s| s["id"] == id }["command"]

  sleep 0.6
  poll = JSON.parse(tool.call("action" => "poll", "sessionId" => id))
  assert_equal "done", poll["status"]
  assert_nil poll["exitCode"] # 0 is omitted (Go omitempty)

  read = JSON.parse(tool.call("action" => "read", "sessionId" => id))
  assert_equal "bg-done\n", read["output"]
  drained = JSON.parse(tool.call("action" => "read", "sessionId" => id))
  assert_nil drained["output"] # destructive drain

  kill_resp = JSON.parse(tool.call("action" => "run", "command" => "sleep 30", "background" => "true"))
  killed = JSON.parse(tool.call("action" => "kill", "sessionId" => kill_resp["sessionId"]))
  assert_equal "done", killed["status"]
  assert_equal "session not found: #{kill_resp["sessionId"]}", tool.call("action" => "poll", "sessionId" => kill_resp["sessionId"])
  assert_equal "session not found: nopenope", tool.call("action" => "read", "sessionId" => "nopenope")
ensure
  FileUtils.rm_rf(w)
end

test "exec background: write to stdin (cat echo), write-after-exit error" do
  w = workspace
  mgr = ExecSessionManager.new
  tool = Exec.new(workspace: w, session_manager: mgr)
  resp = JSON.parse(tool.call("action" => "run", "command" => "cat", "background" => "true"))
  id = resp["sessionId"]
  JSON.parse(tool.call("action" => "write", "sessionId" => id, "data" => "hello\n"))
  sleep 0.2
  read = JSON.parse(tool.call("action" => "read", "sessionId" => id))
  assert_includes read["output"], "hello"
  tool.call("action" => "kill", "sessionId" => id)

  done = JSON.parse(tool.call("action" => "run", "command" => "true", "background" => "true"))
  sleep 0.2
  assert_equal "process already exited with code 0", tool.call("action" => "write", "sessionId" => done["sessionId"], "data" => "x")
ensure
  FileUtils.rm_rf(w)
end

test "exec send-keys: encoding, errors, Sent keys response" do
  w = workspace
  mgr = ExecSessionManager.new
  tool = Exec.new(workspace: w, session_manager: mgr)
  resp = JSON.parse(tool.call("action" => "run", "command" => "cat", "background" => "true"))
  id = resp["sessionId"]
  sent = JSON.parse(tool.call("action" => "send-keys", "sessionId" => id, "keys" => "up, enter"))
  assert_equal "Sent keys: [up enter]", sent["output"]
  sleep 0.2
  assert_includes JSON.parse(tool.call("action" => "read", "sessionId" => id))["output"], "\e[A\r"

  assert_equal "invalid key: unknown key: wat (use write action for text input)",
               tool.call("action" => "send-keys", "sessionId" => id, "keys" => "wat")
  assert_equal "keys cannot be empty", tool.call("action" => "send-keys", "sessionId" => id, "keys" => "")
  assert_equal "keys must be a string", tool.call("action" => "send-keys", "sessionId" => id, "keys" => 5)
  tool.call("action" => "kill", "sessionId" => id)
ensure
  FileUtils.rm_rf(w)
end

test "exec background: 1MB output buffer marker" do
  w = workspace
  mgr = ExecSessionManager.new
  tool = Exec.new(workspace: w, session_manager: mgr)
  resp = JSON.parse(tool.call("action" => "run", "command" => "seq 1 300000", "background" => "true"))
  id = resp["sessionId"]
  30.times do
    break if JSON.parse(tool.call("action" => "poll", "sessionId" => id))["status"] == "done"
    sleep 0.2
  end
  out = JSON.parse(tool.call("action" => "read", "sessionId" => id))["output"]
  assert_includes out, "[output truncated, exceeded 1MB]"
ensure
  FileUtils.rm_rf(w)
end

test "exec background: PTY run" do
  w = workspace
  mgr = ExecSessionManager.new
  tool = Exec.new(workspace: w, session_manager: mgr)
  resp = tool.call("action" => "run", "command" => "echo pty-ok; sleep 0.3", "background" => "true", "pty" => "true")
  if resp.include?("failed to create PTY")
    puts "  skip (no PTY in this environment)"
  else
    id = JSON.parse(resp)["sessionId"]
    sleep 0.6
    out = JSON.parse(tool.call("action" => "read", "sessionId" => id))["output"]
    assert_includes out, "pty-ok"
  end
ensure
  FileUtils.rm_rf(w)
end

# --- ExecKeys unit tests --------------------------------------------------------------

test "ExecKeys: named keys, modifiers, SS3 mode, detection" do
  assert_equal "\r", ExecKeys.encode_token("enter", ExecKeys::MODE_CSI)
  assert_equal "\e[A", ExecKeys.encode_token("up", ExecKeys::MODE_CSI)
  assert_equal "\eOA", ExecKeys.encode_token("up", ExecKeys::MODE_SS3)
  assert_equal "\x03", ExecKeys.encode_token("c-c", ExecKeys::MODE_CSI)
  assert_equal "\x04", ExecKeys.encode_token("ctrl-d", ExecKeys::MODE_CSI)
  assert_equal "\ex", ExecKeys.encode_token("alt-x", ExecKeys::MODE_CSI)
  assert_equal "\ex", ExecKeys.encode_token("m-x", ExecKeys::MODE_CSI)
  assert_equal "\e[Z", ExecKeys.encode_token("btab", ExecKeys::MODE_CSI)
  err = assert_raises(ArgumentError) { ExecKeys.encode_token("wat", ExecKeys::MODE_CSI) }
  assert_equal "unknown key: wat (use write action for text input)", err.message
  assert_equal ExecKeys::MODE_SS3, ExecKeys.detect_pty_key_mode("abc\e[?1h")
  assert_equal ExecKeys::MODE_CSI, ExecKeys.detect_pty_key_mode("abc\e[?1l")
  assert_equal ExecKeys::MODE_CSI, ExecKeys.detect_pty_key_mode("\e[?1h x \e[?1l") # last one wins
  assert_equal ExecKeys::MODE_NOT_FOUND, ExecKeys.detect_pty_key_mode("plain")
end

# --- main.rb wiring ----------------------------------------------------------------

test "main.rb: stack builds, six tools registered under picoclaw names, stand-ins gone" do
  ENV["OPENROUTER_API_KEY"] ||= "dummy"
  load "#{ROOT}/main.rb"
  config = load_config
  build_agent(config) # raises if any middleware wiring is broken
  tools = Brute.tools(build_tools(config, cron_store: CronStore.new(File.join(Dir.pwd, "cron", "jobs.json")))).keys.map(&:to_s)
  %w[read_file write_file edit_file append_file list_dir exec cron web_search].each do |name|
    assert_includes tools.join(","), name
  end
  %w[read write patch shell fs_search].each do |standin|
    refute_includes tools.join(",").split(","), standin
  end
end

puts "\n#{$count} tests, #{$failures.size} failures"
exit($failures.empty? ? 0 : 1)
