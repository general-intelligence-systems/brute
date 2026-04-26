require 'brute/tools/fs_read'
require 'brute/tools/fs_write'
require 'brute/tools/fs_patch'
require 'brute/tools/fs_remove'
require 'brute/tools/fs_search'
require 'brute/tools/fs_undo'
require 'brute/tools/shell'
require 'brute/tools/net_fetch'
require 'brute/tools/todo_write'
require 'brute/tools/todo_read'
require 'brute/tools/delegate'
require 'brute/tools/question'

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
