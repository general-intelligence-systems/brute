# frozen_string_literal: true

# ModelRouter — picoclaw's light/heavy turn routing (pkg/routing/: router.go,
# features.go, classifier.go).
#
# RuleClassifier scores the incoming turn:
#   attachments (data: URIs or media extensions) → 1.0 hard gate
#   tokens >200 +0.35, 50–200 +0.15   (CJK runes = 1 token, others = 0.25)
#   fenced code block +0.40
#   recent tool calls (last 6 history entries) >3 +0.25, 1–3 +0.10
#   conversation depth >10 +0.10
#   capped at 1.0
# score < threshold (default 0.35) → light model, written to
# env[:metadata][:llm_model] for the terminal proc. Enabled only when
# routing.enabled and routing.light_model are configured.
class ModelRouter
  DEFAULT_THRESHOLD = 0.35
  LOOKBACK_WINDOW = 6
  MEDIA_EXTS = %w[.jpg .jpeg .png .gif .webp .bmp .mp3 .wav .ogg .m4a .flac .mp4 .avi .mov .webm].freeze

  def initialize(app, enabled: false, light_model: nil, threshold: DEFAULT_THRESHOLD)
    @app = app
    @enabled = enabled
    @light_model = light_model
    @threshold = threshold.to_f.positive? ? threshold.to_f : DEFAULT_THRESHOLD
  end

  def call(env)
    if @enabled && !@light_model.to_s.empty?
      current = env[:messages].reverse.find { |m| m.role.to_sym == :user }
      score = self.class.score(current&.content.to_s, env[:messages][0...-1] || [])
      env[:metadata][:llm_model] = @light_model if score < @threshold
      env[:metadata][:routing_score] = score
    end
    @app.call(env)
  end

  def self.score(message, history)
    features = Features.extract(message, history)
    return 1.0 if features[:attachments]

    score = 0.0
    tokens = features[:token_estimate]
    score += 0.35 if tokens > 200
    score += 0.15 if tokens > 50 && tokens <= 200
    score += 0.40 if features[:code_blocks].positive?
    recent = features[:recent_tool_calls]
    score += 0.25 if recent > 3
    score += 0.10 if recent.positive? && recent <= 3
    score += 0.10 if features[:depth] > 10
    [score, 1.0].min
  end

  module Features
    module_function

    def extract(message, history)
      {
        token_estimate: estimate_tokens(message),
        code_blocks: message.scan("```").size / 2,
        recent_tool_calls: history.last(LOOKBACK_WINDOW).sum { |m| m.tool_calls.to_a.size },
        depth: history.size,
        attachments: attachments?(message),
      }
    end

    def estimate_tokens(message)
      total = message.length
      return 0 if total.zero?

      cjk = message.count("\u2E80-\u9FFF\uF900-\uFAFF\uAC00-\uD7AF")
      cjk + (total - cjk) / 4
    end

    def attachments?(message)
      lower = message.downcase
      return true if lower.include?("data:image/") || lower.include?("data:audio/") || lower.include?("data:video/")

      MEDIA_EXTS.any? { |ext| lower.include?(ext) }
    end
  end
end
