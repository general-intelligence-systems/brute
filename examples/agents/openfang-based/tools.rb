# frozen_string_literal: true

require "bundler/setup"
require "brute"

# Maps OpenFang builtin tool names (RightNow-AI/openfang) to their brute
# equivalents. Agents declare capabilities.tools in their agent.toml; the
# generated examples pass that list verbatim to OpenFang.tools so the
# mapping — and what has no brute equivalent yet — stays explicit.
module OpenFang
  TOOL_MAP = {
    "file_read"  => Brute::Tools::FSRead,
    "file_write" => Brute::Tools::FSWrite,
    "file_list"  => Brute::Tools::FSSearch,
    "shell_exec" => Brute::Tools::Shell,
    "web_fetch"  => Brute::Tools::NetFetch,
  }.freeze

  # No brute equivalent (yet): web_search, memory_store, memory_recall,
  # agent_send, agent_spawn, agent_list, agent_kill (Brute::Tools::SubAgent
  # covers delegation, but needs per-instance config), browser_* (see
  # examples/agents/browser_agent).
  def self.tools(names)
    names.filter_map { |name| TOOL_MAP[name] }.uniq
  end
end
