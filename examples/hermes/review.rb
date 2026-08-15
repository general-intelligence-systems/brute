# frozen_string_literal: true

require "json"
require_relative "review_prompts"

module Hermes
  # The learning-loop review — plain functions driven by main.rb, NOT
  # middleware. Hermes forks a daemon thread because it's a long-lived app;
  # our process is one turn, so the review is simply a second Brute.agent
  # started right after the first returns. See MIDDLEWARE.md §5.
  #
  # Port of agent/background_review.py: prompt selection, the routed-model
  # digest, and the action summarizer.
  module Review
    module_function

    # memory/skills/combined by which nudges fired + the whitelist suffix;
    # focus: appends the user-steering paragraph (hermes /refine).
    def select_prompt(review_memory:, review_skills:, focus: nil)
      prompt =
        if review_memory && review_skills then ReviewPrompts::COMBINED_REVIEW_PROMPT
        elsif review_memory               then ReviewPrompts::MEMORY_REVIEW_PROMPT
        else                                   ReviewPrompts::SKILL_REVIEW_PROMPT
        end

      prompt += ReviewPrompts::TOOL_WHITELIST_SUFFIX
      unless focus.to_s.strip.empty?
        prompt += "\n\nThe user explicitly requested this review with the following " \
                  "focus — prioritize it over the general instructions above:\n#{focus.strip}"
      end
      prompt
    end

    # Compact replay for the routed (different-model) path only. Keeps the
    # recent tail verbatim, collapses older turns into one synthetic user-role
    # digest — role alternation preserved. Port of _digest_history.
    def digest(messages, tail: 24)
      msgs = messages.to_a
      return msgs if msgs.size <= tail

      keep = msgs.last(tail)
      while keep.first&.role == :tool
        tail += 1
        return msgs if msgs.size <= tail

        keep = msgs.last(tail)
      end

      old = msgs.first(msgs.size - keep.size)
      lines = old.filter_map do |m|
        text = m.content.to_s.gsub("\n", " ").strip
        case m.role
        when :user
          "USER: #{text[0, 300]}" unless text.empty?
        when :assistant
          parts = []
          names = Array(m.respond_to?(:tool_calls) ? m.tool_calls : []).map { |tc| tc.respond_to?(:name) ? tc.name.to_s : tc[:name].to_s }
          parts << "ASSISTANT[tools: #{names.join(', ')}]" unless names.empty?
          parts << "ASSISTANT: #{text[0, 200]}" unless text.empty?
          parts.join("\n") unless parts.empty?
        end
      end

      [Brute::Message.new(
        role: :user,
        content: "[Earlier conversation digest — older turns summarised to bound the " \
                 "review's cold-write cost on the routed aux model. Recent turns " \
                 "follow verbatim below.]\n" + lines.join("\n"),
      )] + keep
    end

    # Successful memory/skill_manage actions from the messages the review
    # produced (everything from index `from` onward — i.e. beyond the replayed
    # history + prompt). notifications: "off" | "on" | "verbose".
    # Port of summarize_background_review_actions.
    def summarize(messages, from:, notifications: "on")
      return [] if notifications.to_s == "off"

      verbose = notifications.to_s == "verbose"
      fresh = messages.to_a[from..] || []

      call_details = {}
      fresh.each do |m|
        next unless m.role == :assistant

        Array(m.respond_to?(:tool_calls) ? m.tool_calls : []).each do |tc|
          name = tc.respond_to?(:name) ? tc.name.to_s : tc[:name].to_s
          next unless %w[memory skill_manage].include?(name)

          id = tc.respond_to?(:id) ? tc.id : tc[:id]
          args = tc.respond_to?(:arguments) ? tc.arguments : tc[:arguments]
          args = args.transform_keys(&:to_s) if args.is_a?(Hash)
          call_details[id] = { "tool" => name, "args" => args || {} }
        end
      end

      fresh.filter_map do |m|
        next unless m.role == :tool

        id = m.respond_to?(:tool_call_id) ? m.tool_call_id : m[:tool_call_id]
        detail = call_details[id]
        next unless detail

        data = begin
          JSON.parse(m.content.to_s)
        rescue JSON::ParserError
          nil
        end
        next unless data.is_a?(Hash) && data["success"]

        build_action(detail, data, verbose)
      end
    end

    def build_action(detail, data, verbose)
      tool = detail["tool"]
      args = detail["args"]
      message = data["message"].to_s

      unless verbose
        ml = message.downcase
        return message if ml.include?("created") || ml.include?("updated")
        return message if tool == "skill_manage" && ml.include?("patched")

        label = tool == "skill_manage" ? "Skill" : (args["target"] == "user" ? "User profile" : "Memory")
        if ml.include?("added") || ml.include?("replaced") || ml.include?("removed") ||
           ml.include?("applied") || (!args["target"].to_s.empty? && ml.include?("add"))
          return "#{label} updated"
        end

        return message.empty? ? nil : message
      end

      label = tool == "skill_manage" ? "📝 Skill" : (args["target"] == "user" ? "User profile" : "Memory")
      action = args["action"].to_s
      content = args["content"].to_s
      old = args["old_text"].to_s.empty? ? args["old_string"].to_s : args["old_text"].to_s

      case action
      when "add"     then content.empty? ? "#{label} updated" : "#{label} ➕ #{preview(content, 120)}"
      when "replace" then content.empty? ? "#{label} updated" : "#{label} ✏️ #{preview(content, 120)}"
      when "remove"  then old.empty? ? "#{label} updated" : "#{label} ➖ #{preview(old, 60)}"
      when "patch"
        old_s = args["old_string"].to_s
        new_s = args["new_string"].to_s
        old_s.empty? && new_s.empty? ? "📝 #{message}" : "📝 Skill '#{args['name']}' patched: \"#{preview(old_s, 80)}\" → \"#{preview(new_s, 80)}\""
      when "create"  then "📝 Skill '#{args['name']}' created"
      when "batch"
        ops = args["operations"].is_a?(Array) ? args["operations"] : []
        return "#{label} updated" if ops.empty?

        ops.filter_map { |op|
          op = op.transform_keys(&:to_s)
          case op["action"]
          when "add"     then "#{label} ➕ #{preview(op['content'].to_s, 120)}"
          when "replace" then "#{label} ✏️ #{preview(op['content'].to_s, 120)}"
          when "remove"  then "#{label} ➖ #{preview(op['old_text'].to_s, 60)}"
          end
        }.join(" · ")
      else message.empty? ? "#{label} updated" : message
      end
    end

    def preview(text, max)
      text = text.gsub("\n", " ")
      text.length > max ? "#{text[0, max]}…" : text
    end
  end
end
