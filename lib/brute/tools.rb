require_relative 'tools/fs_read'
require_relative 'tools/fs_write'
require_relative 'tools/fs_patch'
require_relative 'tools/fs_remove'
require_relative 'tools/fs_search'
require_relative 'tools/fs_undo'
require_relative 'tools/shell'
require_relative 'tools/net_fetch'
require_relative 'tools/todo_write'
require_relative 'tools/todo_read'
require_relative 'tools/delegate'
require_relative 'tools/question'

module Brute
  module Tools
    ALL = [
      Tools::FSRead,
      Tools::FSWrite,
      Tools::FSPatch,
      Tools::FSRemove,
      Tools::FSSearch,
      Tools::FSUndo,
      Tools::Shell,
      Tools::NetFetch,
      Tools::TodoWrite,
      Tools::TodoRead,
      Tools::Delegate,
      Tools::Question
    ].freeze
  end
end
