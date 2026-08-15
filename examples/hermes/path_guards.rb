# frozen_string_literal: true

module Hermes
  # Path guards for the file tools — the workspace-scoped subset of
  # hermes-agent's tools/path_security.py + credential-store guards.
  # (Cross-profile and install-tree guards are N/A to this port.)
  module PathGuards
    # Never read or write these via the file tools: credential stores and
    # key material. Matches hermes' sensitive-path guard intent.
    SENSITIVE_PATTERNS = [
      /\.env(\.|$)/i,
      /(^|\/)id_rsa|\.pem$|\.key$/i,
      /credentials(\.json|\.store)?$|\.netrc$|\.pgpass$|\.npmrc$|\.pypirc/i,
    ].freeze

    module_function

    # Returns an error string when the path is guarded, nil when clean.
    def check(path)
      p = path.to_s
      if SENSITIVE_PATTERNS.any? { |re| re.match?(p) }
        return "Refusing to touch '#{path}': credential/secret files are off-limits " \
               "to the file tools. Use dedicated config or secret tooling."
      end
      nil
    end

    # V4A header paths come from patch CONTENT (attacker-influenceable):
    # reject '..' traversal there. (The explicit path arg may legitimately
    # use '..' — hermes makes the same distinction.)
    def traversal?(path)
      path.to_s.split(/[\/\\]/).include?("..")
    end

    # read_file's display text carries "N|" line-number prefixes — writing it
    # back as file content corrupts the file. hermes: _is_internal_file_tool_content.
    def internal_display_text?(content)
      lines = content.to_s.lines
      return false if lines.size < 2

      numbered = lines.count { |l| l =~ /\A\d+\|/ }
      numbered >= 2 && numbered >= (lines.size * 0.8)
    end
  end
end
