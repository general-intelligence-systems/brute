# frozen_string_literal: true

require "json"
require "fileutils"

# StateManager — picoclaw's tiny persistent KV (pkg/state/state.go).
#
# Tracks {last_channel, last_chat_id, timestamp} in <workspace>/state/
# state.json (atomic temp+rename, 0600). Upstream writes it on every
# non-internal-channel turn and the heartbeat service reads it to target
# delivery. This port's turns are all internal (heartbeat/dev), so the file
# always records cli/direct — written every turn so the file is fresh when
# channel-backed delivery lands.
#
# env reads: none. env writes: none. Side effects: state.json write on unwind.
class StateManager
  def initialize(app, path: File.join(Dir.pwd, "state", "state.json"))
    @app = app
    @path = path
  end

  def call(env)
    @app.call(env)
    write_state
    env
  end

  private

  def write_state
    FileUtils.mkdir_p(File.dirname(@path))
    tmp = "#{@path}.tmp"
    File.write(tmp, "#{JSON.pretty_generate(
      "last_channel" => "cli",
      "last_chat_id" => "direct",
      "timestamp" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
    )}\n")
    File.chmod(0o600, tmp)
    File.rename(tmp, @path)
  rescue SystemCallError => e
    warn "state_manager: #{e.message}"
  end
end
