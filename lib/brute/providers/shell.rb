# frozen_string_literal: true

require "shellwords"

module Brute
  module Providers
    # A pseudo-LLM provider that executes user input as code via the
    # existing Brute::Tools::Shell tool.
    #
    # Models correspond to interpreters:
    #
    #   bash   - pass-through (default)
    #   ruby   - ruby -e '...'
    #   python - python3 -c '...'
    #   nix    - nix eval --expr '...'
    #
    # The provider's #complete method returns a synthetic response
    # containing a single "shell" tool call. The agent loop executes
    # it through the normal pipeline — all middleware (message tracking,
    # session persistence, token tracking, etc.) fires as usual.
    #
    class Shell
      MODELS = %w[bash ruby python nix].freeze

      INTERPRETERS = {
        "bash"   => ->(cmd) { cmd },
        "ruby"   => ->(cmd) { "ruby -e #{Shellwords.escape(cmd)}" },
        "python" => ->(cmd) { "python3 -c #{Shellwords.escape(cmd)}" },
        "nix"    => ->(cmd) { "nix eval --expr #{Shellwords.escape(cmd)}" },
      }.freeze

      # ── Provider interface ─────────────────────────────────────────

      def name           = :shell
      def default_model  = "bash"

      def complete(prompt, params = {})
        model = params[:model]&.to_s || default_model
        text  = extract_text(prompt)
        tools = params[:tools] || []

        # nil text means we received tool results (second call) —
        # return an empty assistant response so the agent loop exits.
        return ShellResponse.new(model: model, tools: tools) if text.nil?

        wrap    = INTERPRETERS.fetch(model, INTERPRETERS["bash"])
        command = wrap.call(text)

        ShellResponse.new(command: command, model: model, tools: tools)
      end

      # For the REPL model picker: provider.models.all.select(&:chat?)
      def models
        ModelList.new(MODELS)
      end

      # ── Internals ──────────────────────────────────────────────────

      private

      # Extract the user's text from the messages array.
      # Returns nil when the messages contain tool results (the second
      # round-trip) so #complete knows to return an empty response.
      def extract_text(prompt)
        case prompt
        when String
          prompt
        when ::Array
          return nil if prompt.any? { |m| m.respond_to?(:role) && m.role == :tool }

          user_msg = prompt.reverse_each.find { |m| m.respond_to?(:role) && m.role == :user }
          user_msg&.content.to_s
        else
          prompt.to_s
        end
      end

      # ── ModelList ──────────────────────────────────────────────────

      # Minimal object that quacks like provider.models so the REPL's
      # fetch_models can call provider.models.all.select(&:chat?).
      class ModelList
        ModelEntry = Struct.new(:id, :chat?, keyword_init: true)

        def initialize(names)
          @entries = names.map { |n| ModelEntry.new(id: n, chat?: true) }
        end

        def all
          @entries
        end
      end
    end
  end
end
