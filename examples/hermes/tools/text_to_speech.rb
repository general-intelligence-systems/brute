# frozen_string_literal: true

require "json"

# text_to_speech — hermes toolset: tts
# Port of hermes-agent `tools/tts_tool.py:4490` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_tts_requirements
module HermesTools
  class TextToSpeech < Brute::Tool
    description "Convert text to speech audio. Returns a MEDIA: path that the platform delivers as native audio. Compatible providers render as a voice bubble on Telegram; otherwise audio is sent as a regular attachment. In CLI mode, saves to ~/voice-memos/. Voice and provider are user-configured (built-in providers like edge/openai or custom command providers under tts.providers.<name>), not model-selected."
    params({ "type" => "object", "properties" => { "text" => { "type" => "string", "description" => "The text to convert to speech. Provider-specific per-request character caps apply automatically (OpenAI 4096, xAI 15000, MiniMax 10000, ElevenLabs 5k-40k depending on model); longer input is split into ordered chunks without silent truncation." }, "output_path" => { "type" => "string", "description" => "Optional custom file path to save the audio. Defaults to {dynamic}/audio_cache/<timestamp>.mp3" }, "speed" => { "type" => "number", "description" => "Playback speed multiplier. 1.0 = normal, 0.5 = very slow (language learning), 2.0 = fast. Range: 0.25-4.0. Overrides the speed configured in config.yaml." }, "instructions" => { "type" => "string", "description" => "Optional voice-design guidance: tone, emotion, pacing, accent, whispering, impressions (e.g. 'Speak in a cheerful, excited whisper'). Forwarded to the OpenAI backend (gpt-4o-mini-tts and OpenAI-compatible voice-design servers). Silently ignored by backends that don't support it." }, "provider" => { "type" => "string", "description" => "Optional TTS provider override. Accepts built-in names (edge, openai, elevenlabs, minimax, xai, mistral, gemini, neutts, kittentts, piper), user-declared command provider names from tts.providers.<name>, or plugin-registered names. When omitted, the configured tts.provider from config.yaml is used." } }, "required" => ["text"] })
    def name = "text_to_speech"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "text_to_speech")
    end
  end
end
