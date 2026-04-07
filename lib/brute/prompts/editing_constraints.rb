# frozen_string_literal: true

module Brute
  module Prompts
    module EditingConstraints
      TEXT = <<~TXT
        # Editing constraints

        - Default to ASCII when editing or creating files. Only introduce non-ASCII or other Unicode characters when there is a clear justification and the file already uses them.
        - Add succinct code comments that explain what is going on if code is not self-explanatory. Usage of these comments should be rare.
        - Always use the patch tool for manual code edits. Do not use shell commands when creating or editing files.
        - NEVER revert existing changes you did not make unless explicitly requested, since these changes were made by the user.
        - You may be in a dirty git worktree.
          * If asked to make a commit or code edits and there are unrelated changes to your work or changes that you didn't make in those files, don't revert those changes.
          * If the changes are in files you've touched recently, read carefully and understand how you can work with the changes rather than reverting them.
          * If the changes are in unrelated files, just ignore them and don't revert them.
      TXT

      def self.call(_ctx)
        TEXT
      end
    end
  end
end
