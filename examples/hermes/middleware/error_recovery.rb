# frozen_string_literal: true

require "json"
require "openssl"
require_relative "interrupt"

module Hermes
  module Middleware
    # ErrorRecovery — classified API-error recovery around the LLM call
    # (per-iteration). Port of hermes-agent's error_classifier.py taxonomy +
    # the conversation_loop retry machinery + empty-response recovery
    # (run_agent.py:1942).
    #
    # THE REASON TABLE — every FailoverReason with its recovery branch:
    #
    #   reason                  branch
    #   ──────────────────────  ─────────────────────────────────────────────
    #   auth (401/403)          one refresh retry, then terminal (permanent)
    #   billing (402/quota)     terminal with top-up guidance
    #   rate_limit (429)        jittered backoff, retry ≤ max_retries
    #   upstream_rate_limit     fallback model (NOT credential rotation)
    #   overloaded (503/529)    jittered backoff, retry
    #   server_error (500/502)  retry
    #   timeout                 jittered backoff, retry
    #   ssl_cert_verification   terminal (deterministic — retry replays it)
    #   context_overflow        compactor.compress! then retry (≤3 attempts)
    #   payload_too_large (413) compactor.compress! then retry (≤3 attempts)
    #   model_not_found (404)   fallback model once per turn
    #   content_policy_blocked  one fallback try, else terminal blocked result
    #   format_error (400)      terminal
    #   unknown                 jittered backoff, retry ≤ max_retries
    #
    # Terminal failure NEVER raises through the turn: an assistant message
    # explains, should_exit is set.
    #
    # Empty-response recovery: an empty assistant reply after tool results is
    # answered with a stamped "(empty)" + nudge pair and an internal retry
    # (≤2). Stamped scaffolding is recorded in env[:ephemeral_messages] so
    # SessionStore skips it; on exhaustion the scaffolding and its owning
    # tool/assistant pair are rewound (hermes' two-pass drop).
    class ErrorRecovery
      MAX_COMPRESSION_ATTEMPTS = 3
      MAX_EMPTY_RETRIES = 2
      EMPTY_NUDGE =
        "You just executed tool calls but returned an " \
        "empty response. Please process the tool " \
        "results above and continue with the task."

      def initialize(app, compactor: nil, fallback_model: nil, max_retries: 2,
                     sleep_proc: nil)
        @app = app
        @compactor = compactor
        @fallback_model = fallback_model
        @max_retries = max_retries
        @sleep = sleep_proc || ->(seconds) { sleep(seconds) }
      end

      def call(env)
        attempts = 0
        compression_attempts = 0
        auth_retried = false

        loop do
          begin
            @app.call(env)
            handle_empty_response(env)
            return env
          rescue StandardError => e
            reason = classify(e)

            case reason
            when :rate_limit, :overloaded, :server_error, :timeout, :unknown
              attempts += 1
              return terminal(env, reason, e) if attempts > @max_retries

              return terminal(env, reason, e) unless backoff(attempts, env)
              next

            when :auth
              return terminal(env, :auth_permanent, e) if auth_retried

              auth_retried = true
              next

            when :context_overflow, :payload_too_large
              compression_attempts += 1
              return terminal(env, reason, e) unless @compactor && compression_attempts <= MAX_COMPRESSION_ATTEMPTS

              compacted = @compactor.compress(env[:messages])
              next unless compacted

              env[:messages] = compacted.extend(Brute::Messages)
              env[:invalidate_system_prompt] = true
              env[:events] << { type: :compaction, data: { trigger: reason } }
              next

            when :model_not_found, :upstream_rate_limit, :content_policy_blocked
              if @fallback_model && !env[:_fallback_used]
                env[:_fallback_used] = true
                env[:model] = @fallback_model
                attempts = 0
                next
              end
              return terminal(env, reason, e)

            when :billing, :ssl_cert_verification, :format_error
              return terminal(env, reason, e)
            end
          end
        end
      end

      # -- Classification ---------------------------------------------------------

      # Every reason classified — status code first, then message patterns.
      def classify(error)
        status = error.respond_to?(:status) ? error.status.to_i : error.message[/\b(\d{3})\b/, 1]&.to_i
        msg = error.message.to_s

        case
        when error.is_a?(OpenSSL::SSL::SSLError) || msg =~ /certificate verify failed|SSL_connect/i
          :ssl_cert_verification
        when error.is_a?(Timeout::Error) || defined?(Net::ReadTimeout) && error.is_a?(Net::ReadTimeout) || msg =~ /timed? ?out/i
          :timeout
        when status == 401 || status == 403 then :auth
        when status == 402 || msg =~ /insufficient|quota|balance|credit/i then :billing
        when status == 429
          msg =~ /upstream|provider.?rate|model.?rate/i ? :upstream_rate_limit : :rate_limit
        when [500, 502].include?(status) then :server_error
        when [503, 529].include?(status) || msg =~ /overload/i then :overloaded
        when status == 404 || msg =~ /model.?not.?found|no.?endpoints?/i then :model_not_found
        when status == 413 then :payload_too_large
        when msg =~ /context.?length|too.?many.?tokens|maximum.?context|token.?limit|reduce.?length/i then :context_overflow
        when msg =~ /content.?policy|safety|moderation|blocked|filter/i then :content_policy_blocked
        when status == 400 then :format_error
        else :unknown
        end
      end

      # -- Branches ---------------------------------------------------------------

      # Jittered backoff, interruptible in 0.2s slices (hermes touches
      # activity and honors redirects during the wait). Returns false when
      # interrupted (caller goes terminal).
      def backoff(attempt, env)
        delay = [5.0 * attempt + rand(0.0..2.0), 120.0].min
        deadline = Time.now + delay
        while Time.now < deadline
          return false if Hermes::Interrupt.requested?

          @sleep.call([deadline - Time.now, 0.2].min)
        end
        true
      end

      def terminal(env, reason, error)
        message =
          case reason
          when :auth_permanent
            "Authentication failed (401/403). Check your API key — it was rejected after a refresh attempt."
          when :billing
            "Provider billing/quota exhausted: #{error.message.to_s[0, 200]}. Top up or switch provider."
          when :ssl_cert_verification
            "TLS certificate verification failed — this is deterministic. Fix your CA bundle or proxy configuration."
          when :content_policy_blocked
            "The provider's safety filter rejected this request."
          when :format_error
            "The provider rejected the request format (400): #{error.message.to_s[0, 200]}"
          when :model_not_found
            "Model not found (404) and no fallback model configured."
          when :context_overflow, :payload_too_large
            "Context too large and #{MAX_COMPRESSION_ATTEMPTS} compression attempts could not fit it."
          else
            "Provider unavailable after #{@max_retries} retries (#{reason}): #{error.message.to_s[0, 200]}"
          end

        env[:messages] << Brute::Message.new(role: :assistant, content: "⚠️ #{message}")
        env[:should_exit] = { reason: "error", error: message, classified: reason }
        env
      end

      # -- Empty-response recovery ------------------------------------------------

      def handle_empty_response(env)
        tries = 0
        while empty_response?(env) && tries < MAX_EMPTY_RETRIES
          tries += 1
          scaffold = [
            Brute::Message.new(role: :assistant, content: "(empty)"),
            Brute::Message.new(role: :user, content: EMPTY_NUDGE),
          ]
          env[:messages].concat(scaffold)
          (env[:ephemeral_messages] ||= []).concat(scaffold.map(&:object_id))
          @app.call(env)
        end

        if empty_response?(env)
          # Exhaustion: rewind the trailing scaffolding AND the tool/assistant
          # pair that owned it (hermes' two-pass drop), then end the turn.
          drop_trailing_scaffolding(env)
        end
        env
      end

      def empty_response?(env)
        last = env[:messages].last
        return false unless last&.role == :assistant
        return false unless last.content.to_s.strip.empty?

        tool_calls = last.respond_to?(:tool_calls) ? last.tool_calls : nil
        return false if tool_calls && !tool_calls.empty?

        env[:messages].any? { |m| m.role == :tool }
      end

      def drop_trailing_scaffolding(env)
        # Pop every trailing empty response AND stamped scaffold in one pass
        # (they interleave across retries), then rewind the tool/assistant
        # pair that owned the loop (hermes' two-pass rewind).
        ephemeral = env[:ephemeral_messages] || []
        env[:messages].pop while env[:messages].any? &&
          (empty_assistant?(env[:messages].last) || ephemeral.include?(env[:messages].last.object_id))
        env[:messages].pop while env[:messages].any? && env[:messages].last.role == :tool
        if env[:messages].any? && env[:messages].last.role == :assistant &&
           (env[:messages].last.respond_to?(:tool_calls) && env[:messages].last.tool_calls&.any?)
          env[:messages].pop
        end
        env[:messages] << Brute::Message.new(
          role: :assistant,
          content: "⚠️ The model returned an empty response repeatedly. Please try again.",
        )
        env[:should_exit] = { reason: "empty_response_exhausted" }
      end

      def empty_assistant?(message)
        return false unless message.role == :assistant
        return false unless message.content.to_s.strip.empty?

        tool_calls = message.respond_to?(:tool_calls) ? message.tool_calls : nil
        tool_calls.nil? || tool_calls.empty?
      end
    end
  end
end
