# frozen_string_literal: true

require "bundler/setup"
require "brute"

require_relative "tools/memory"
require_relative "tools/web_search"
require_relative "tools/agents"
require_relative "tools/browser"

# Maps OpenFang builtin tool names (RightNow-AI/openfang) to their brute
# equivalents. Agents declare capabilities.tools in their agent.toml; the
# generated examples pass that list verbatim to OpenFang.tools.
#
# The map is total over the 18 tool names the 31 agent manifests declare:
# five resolve to brute's own tools, the rest are implemented under tools/
# with their names, descriptions, and parameter schemas copied verbatim
# from openfang's tool_runner.rs.
module OpenFang
  TOOL_MAP = {
    # brute builtins
    "file_read"  => Brute::Tools::FSRead,
    "file_write" => Brute::Tools::FSWrite,
    "file_list"  => Brute::Tools::FSSearch,
    "shell_exec" => Brute::Tools::Shell,
    "web_fetch"  => Brute::Tools::NetFetch,

    # ported in tools/ (surfaces verbatim from openfang tool_runner.rs)
    "web_search"    => OpenFang::Tools::WebSearch,
    "memory_store"  => OpenFang::Tools::MemoryStore,
    "memory_recall" => OpenFang::Tools::MemoryRecall,
    "agent_send"    => OpenFang::Tools::AgentSend,
    "agent_spawn"   => OpenFang::Tools::AgentSpawn,
    "agent_list"    => OpenFang::Tools::AgentList,
    "agent_kill"    => OpenFang::Tools::AgentKill,

    # ported in tools/, backed by the browser-agent port's Ferrum driver
    "browser_navigate"   => OpenFang::Tools::BrowserNavigate,
    "browser_click"      => OpenFang::Tools::BrowserClick,
    "browser_type"       => OpenFang::Tools::BrowserType,
    "browser_screenshot" => OpenFang::Tools::BrowserScreenshot,
    "browser_read_page"  => OpenFang::Tools::BrowserReadPage,
    "browser_close"      => OpenFang::Tools::BrowserClose,
  }.freeze

  def self.tools(names)
    names.filter_map { |name| TOOL_MAP[name] }.uniq
  end
end
