# frozen_string_literal: true

require "json"

# browser_dialog — hermes toolset: browser-cdp
# Port of hermes-agent `tools/browser_dialog_tool.py:136` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _browser_dialog_check
module HermesTools
  class BrowserDialog < Brute::Tool
    description "Respond to a native JavaScript dialog (alert / confirm / prompt / beforeunload) that is currently blocking the page.\n\n**Workflow:** call ``browser_snapshot`` first — if a dialog is open, it appears in the ``pending_dialogs`` field with ``id``, ``type``, and ``message``. Then call this tool with ``action='accept'`` or ``action='dismiss'``.\n\n**Prompt dialogs:** pass ``prompt_text`` to supply the response string. Ignored for alert/confirm/beforeunload.\n\n**Multiple dialogs:** if more than one dialog is queued (rare — happens when a second dialog fires while the first is still open), pass ``dialog_id`` from the snapshot to disambiguate.\n\n**Availability:** only present when a CDP-capable backend is attached — Browserbase sessions, local Chromium-family browser via ``/browser connect``, or ``browser.cdp_url`` in config.yaml. Not available on Camofox (REST-only) or the default Playwright local browser (CDP port is hidden)."
    params({ "type" => "object", "properties" => { "action" => { "type" => "string", "enum" => ["accept", "dismiss"], "description" => "'accept' clicks OK / returns the prompt text. 'dismiss' clicks Cancel / returns null from prompt(). For ``beforeunload`` dialogs: 'accept' allows the navigation, 'dismiss' keeps the page." }, "prompt_text" => { "type" => "string", "description" => "Response string for a ``prompt()`` dialog. Ignored for other dialog types. Defaults to empty string." }, "dialog_id" => { "type" => "string", "description" => "Specific dialog to respond to, from ``browser_snapshot.pending_dialogs[].id``. Required only when multiple dialogs are queued." } }, "required" => ["action"] })
    def name = "browser_dialog"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "browser_dialog")
    end
  end
end
