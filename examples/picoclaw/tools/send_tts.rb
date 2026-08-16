# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../middleware/media"

# send_tts — picoclaw `pkg/tools/integration/tts_send.go`. Synthesizes speech
# and sends the audio via the outbox. Registered only when a TTS model is
# configured (voice.tts_model_name, or any models[] entry containing "tts") —
# upstream's DetectTTS behavior.
class SendTTS < Brute::Tool
  description "Synthesize speech from text and send it as an audio file to the user."
  params({
    "type" => "object",
    "properties" => {
      "text" => { "type" => "string", "description" => "The text to synthesize into speech. NOTE: Reply in a highly concise, conversational, oral style suitable for text-to-speech. Do not use markdown, emojis, asterisks, or code blocks. Speak naturally." },
      "filename" => { "type" => "string", "description" => "Optional filename for the audio file (e.g., response.ogg)." },
    },
    "required" => ["text"],
  })

  def initialize(outbox:, synthesize:, media_store: nil, media_dir: Media::MEDIA_DIR)
    @outbox = outbox
    @synthesize = synthesize
    @media_store = media_store
    @media_dir = media_dir
  end

  def name = "send_tts"

  def execute(text: nil, filename: nil, **_args)
    return "text is required" unless text.is_a?(String) && !text.strip.empty?

    audio = @synthesize.call(text)
    return "TTS synthesis failed" if audio.to_s.empty?

    FileUtils.mkdir_p(@media_dir)
    filename = filename.to_s.empty? ? "response-#{Time.now.to_i}.ogg" : filename
    path = File.join(@media_dir, File.basename(filename))
    File.binwrite(path, audio)

    ref =
      if @media_store
        @media_store.store(path, meta: { filename: filename, content_type: "audio/ogg",
                                         cleanup_policy: "delete_on_cleanup", source: "tool:send_tts" },
                               scope: "tool:send_tts:cli:direct")
      else
        path
      end
    @outbox.append(channel: "cli", chat_id: "direct", content: "", media: [ref])
    "Audio sent: #{filename}"
  rescue StandardError => e
    warn("send_tts crashed: #{e.class}: #{e.message}")
    e.message
  end
end
