# frozen_string_literal: true

# MCP tests: a live stdio MCP server fixture + the manager (hidden/deferred
# registry, promotion TTL, invoke) + the wrapper (name sanitization, content
# normalization, artifact spill) + the discovery tools.

require "fileutils"
require "tmpdir"
require "json"
require "base64"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "brute"

ROOT = File.expand_path("..", __dir__)
%w[fs_sandbox web_http bm25 mcp_tool mcp_manager tool_search_tool_regex tool_search_tool_bm25].each do |f|
  require_relative "#{ROOT}/tools/#{f}"
end
require_relative "#{ROOT}/middleware/media"

$failures = []
$count = 0

def test(name)
  $count += 1
  yield
  puts "  ok  #{name}"
rescue StandardError, ScriptError => e
  $failures << [name, e]
  puts "FAIL  #{name}: #{e.class}: #{e.message}"
  puts e.backtrace.first(6).map { |l| "      #{l}" }
end

def assert(cond, msg = "expected truthy")
  raise msg unless cond
end

def refute(cond, msg = "expected falsy")
  raise msg if cond
end

def assert_equal(exp, act)
  raise("expected #{exp.inspect}, got #{act.inspect}") unless exp == act
end

def assert_includes(hay, needle)
  raise("expected to include #{needle.inspect}:\n#{hay}") unless hay.include?(needle)
end

def assert_match(pattern, str)
  raise("expected #{str.inspect} to match #{pattern.inspect}") unless str.match?(pattern)
end

def workspace
  Dir.mktmpdir("picoclaw-mcp-test")
end

FIXTURE = File.expand_path("mcp_fixture.rb", __dir__)

# A minimal MCP server speaking newline-framed JSON-RPC over stdio.
def write_fixture(dir)
  path = File.join(dir, "mcp_fixture.rb")
  File.write(path, <<~RUBY)
    require "json"
    require "base64"
    $stdout.sync = true
    $stdin.each_line do |line|
      begin
        msg = JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      next unless msg["id"]
      result = case msg["method"]
               when "initialize"
                 { "protocolVersion" => msg.dig("params", "protocolVersion") || "2025-03-26",
                   "capabilities" => { "tools" => {} },
                   "serverInfo" => { "name" => "fixture", "version" => "1.0" } }
               when "ping" then {}
               when "tools/list"
                 { "tools" => [
                   { "name" => "echo", "description" => "Echoes text",
                     "inputSchema" => { "type" => "object", "properties" => { "text" => { "type" => "string" } } } },
                   { "name" => "big_text", "description" => "Huge text",
                     "inputSchema" => { "type" => "object", "properties" => {} } },
                   { "name" => "give_image", "description" => "Returns an image",
                     "inputSchema" => { "type" => "object", "properties" => {} } },
                 ] }
               when "tools/call"
                 case msg.dig("params", "name")
                 when "echo"
                   { "content" => [{ "type" => "text", "text" => "echo: \#{msg.dig("params", "arguments", "text")}" }] }
                 when "big_text"
                   { "content" => [{ "type" => "text", "text" => "x" * 20000 }] }
                 when "give_image"
                   { "content" => [{ "type" => "image", "data" => Base64.encode64("PNGDATA"), "mimeType" => "image/png" }] }
                 else
                   { "isError" => true, "content" => [{ "type" => "text", "text" => "unknown tool" }] }
                 end
               end
      puts JSON.generate("jsonrpc" => "2.0", "id" => msg["id"], "result" => result)
    end
  RUBY
  path
end

def mcp_config(dir, discovery: false)
  fixture = write_fixture(dir)
  { "enabled" => true,
    "discovery" => { "enabled" => discovery, "ttl" => 2, "max_search_results" => 5,
                     "use_bm25" => true, "use_regex" => true },
    "servers" => { "test" => { "enabled" => true, "command" => RbConfig.ruby, "args" => [fixture] } } }
end

test "mcp manager: connects, discovers, wraps; name sanitization" do
  w = workspace
  manager = MCPManager.new(config: mcp_config(w), workspace: w).start
  names = manager.tools.map(&:name)
  assert_includes names, "mcp_test_echo"
  tool = manager.tools.find { |t| t.name == "mcp_test_echo" }
  assert_equal "[MCP:test] Echoes text", tool.description
  assert_equal "string", tool.params_schema.dig("properties", "text", "type")

  assert_equal "mcp_x_y", MCPTool.full_name("x", "y")
  weird = MCPTool.full_name("My Server!", "Do.Thing")
  assert weird.start_with?("mcp_my_server_do_thing_")
  assert_match(/_[0-9a-f]{8}\z/, weird) # lossy sanitization appends the FNV hash
  long = MCPTool.full_name("s" * 60, "t" * 60)
  assert long.length <= 64
  manager.stop
ensure
  FileUtils.rm_rf(w)
end

test "mcp: hidden gating, discovery promote, invoke, TTL expiry" do
  w = workspace
  manager = MCPManager.new(config: mcp_config(w, discovery: true), workspace: w).start
  tool = manager.tools.find { |t| t.name == "mcp_test_echo" }
  assert manager.locked?("mcp_test_echo")

  locked = tool.call("text" => "hi")
  assert_includes locked, "not available"

  search = ToolSearchToolBM25.new(manager: manager)
  out = search.call("query" => "echo text")
  assert_includes out, "SUCCESS: These tools have been temporarily UNLOCKED"
  refute manager.locked?("mcp_test_echo")

  assert_equal "echo: hi", tool.call("text" => "hi")

  manager.tick! # ttl 2 → 1
  refute manager.locked?("mcp_test_echo")
  manager.tick! # expires
  assert manager.locked?("mcp_test_echo")

  assert_equal "Missing or invalid 'query' argument. Must be a non-empty string.", search.call("query" => "")
  regex = ToolSearchToolRegex.new(manager: manager)
  assert_includes regex.call("pattern" => "echo"), "UNLOCKED"
  assert_includes regex.call("pattern" => "["), "Invalid regex pattern syntax"
  assert_equal "Pattern too long: max 200 characters allowed", regex.call("pattern" => "x" * 201)
  manager.stop
ensure
  FileUtils.rm_rf(w)
end

test "mcp: large text spills to .artifacts, images go to the media store" do
  w = workspace
  Dir.chdir(w) do
    store = Media::Store.new(dir: w)
    manager = MCPManager.new(config: mcp_config(w), workspace: w, media_store: store).start
    big = manager.tools.find { |t| t.name == "mcp_test_big_text" }
    out = big.call({})
    assert_includes out, "omitted from model context and saved as a local artifact"
    artifact = Dir.glob(File.join(w, ".artifacts", "mcp", "*.txt")).first
    assert artifact
    assert_equal 20_000, File.read(artifact).length

    image = manager.tools.find { |t| t.name == "mcp_test_give_image" }
    out = image.call({})
    assert_includes out, "stored as media://"
    assert File.read(File.join(w, Dir.glob("#{w}/*.png").first.to_s)) rescue nil
    manager.stop
  end
ensure
  FileUtils.rm_rf(w)
end

puts "\n#{$count} tests, #{$failures.size} failures"
exit($failures.empty? ? 0 : 1)
