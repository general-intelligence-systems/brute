# frozen_string_literal: true

require "json"
require "fileutils"

# Outbox — the port's outbound surface (picoclaw's message bus, minus the
# channels): outbound.jsonl in the workspace, one JSON record per line
# ({ts, channel, chat_id, content, media, reply_to_message_id}). An operator
# or a future channel tails it; inbound is steer.jsonl, symmetric.
#
# Also owns the per-round send tracking (picoclaw's message-tool
# HasSentInRound/HasSentTo): when the message tool already delivered to the
# chat this turn, the final reply is suppressed (PublishResponseIfNeeded).
class Outbox
  def initialize(path: File.join(Dir.pwd, "outbound.jsonl"))
    @path = path
    @sent = [] # [channel, chat_id] pairs recorded this round
  end

  def append(channel: "cli", chat_id: "direct", content: "", media: [], reply_to_message_id: nil)
    record = {
      "ts" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
      "channel" => channel,
      "chat_id" => chat_id,
      "content" => content.to_s,
      "media" => media,
      "reply_to_message_id" => reply_to_message_id,
    }
    record.delete("media") if record["media"].empty?
    record.delete("reply_to_message_id") if record["reply_to_message_id"].nil?

    FileUtils.mkdir_p(File.dirname(@path))
    File.open(@path, "a") { |f| f.puts(JSON.generate(record)) }
    @sent << [channel, chat_id]
    record
  end

  def sent_to?(channel, chat_id) = @sent.include?([channel, chat_id])
  def sent_in_round? = @sent.any?

  # Called by the driver between turns (round = one turn).
  def reset_round!
    @sent = []
  end
end
