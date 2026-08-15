# frozen_string_literal: true

# DiffResult — port of pkg/tools/shared/diff_result.go.
#
# Upstream shows the unified diff only to the USER (ForUser, fenced, capped at
# 16KB); the LLM gets the summary plus a note. This port has no user channel,
# so llm_result returns the LLM-facing content — which is what the tool
# returns. Do NOT "fix" this to include the diff: upstream deliberately keeps
# it out of the context.
#
# The unified diff is exact for edit_file's case: old_text occurs exactly
# once, so before/after share a common prefix and suffix and the diff is
# always a single hunk (3 lines of context), rendered the way go-difflib does
# — counts always printed, the "\ No newline at end of file" marker treated as
# an ordinary diff line (prefix included).
module DiffResult
  NO_CHANGE = "(no content change)"
  NO_NEWLINE_MARKER = '\ No newline at end of file'
  SKIPPED = "[diff preview skipped: file too large for inline preview]"
  TRUNCATED_NOTE = "[diff preview truncated; call read_file for the full edited contents]"
  MAX_INPUT_BYTES = 64 * 1024
  MAX_INPUT_LINES = 2000
  MAX_USER_PREVIEW_BYTES = 16 * 1024
  CONTEXT = 3

  module_function

  def llm_result(path, before, after)
    summary = "File edited: #{path}"
    return "#{summary}\n#{SKIPPED}" if exceeds_limits?(before, after)

    diff = build_unified_diff(path, before, after)
    _user_diff, truncated = truncate_preview(diff, MAX_USER_PREVIEW_BYTES)

    if diff == NO_CHANGE
      "#{summary}\n#{NO_CHANGE}"
    elsif truncated
      "#{summary}\n#{TRUNCATED_NOTE}"
    else
      summary
    end
  end

  def exceeds_limits?(before, after)
    before.bytesize > MAX_INPUT_BYTES || after.bytesize > MAX_INPUT_BYTES ||
      count_lines(before) > MAX_INPUT_LINES || count_lines(after) > MAX_INPUT_LINES
  end

  def count_lines(content)
    return 0 if content.empty?

    lines = content.count("\n")
    lines += 1 unless content.end_with?("\n")
    lines
  end

  # Split keeping line endings; a file without a trailing newline gets its
  # last line newline-terminated plus the marker appended as its own line.
  def split_lines_preserving_eof(content)
    return [] if content.empty?

    lines = content.split(/(?<=\n)/)
    unless content.end_with?("\n")
      lines[-1] = "#{lines[-1]}\n"
      lines << "#{NO_NEWLINE_MARKER}\n"
    end
    lines
  end

  def build_unified_diff(path, before, after)
    a = split_lines_preserving_eof(before)
    b = split_lines_preserving_eof(after)

    pre = 0
    pre += 1 while pre < a.size && pre < b.size && a[pre] == b[pre]
    return NO_CHANGE if pre == a.size && pre == b.size

    suf = 0
    suf += 1 while suf < a.size - pre && suf < b.size - pre && a[a.size - 1 - suf] == b[b.size - 1 - suf]

    hunk_start = [pre - CONTEXT, 0].max
    a_mid_end = a.size - suf
    b_mid_end = b.size - suf
    a_hunk_end = [a_mid_end + CONTEXT, a.size].min
    b_hunk_end = [b_mid_end + CONTEXT, b.size].min

    a_count = a_hunk_end - hunk_start
    b_count = b_hunk_end - hunk_start
    # Unified diff convention: a zero-count side numbers the line BEFORE the hunk.
    a_from = a_count.zero? ? hunk_start : hunk_start + 1
    b_from = b_count.zero? ? hunk_start : hunk_start + 1

    display = display_path(path)
    out = +"--- a/#{display}\n+++ b/#{display}\n"
    out << "@@ -#{a_from},#{a_count} +#{b_from},#{b_count} @@\n"
    a[hunk_start...pre].each { |line| out << " " << line }
    a[pre...a_mid_end].each { |line| out << "-" << line }
    b[pre...b_mid_end].each { |line| out << "+" << line }
    a[a_mid_end...a_hunk_end].each { |line| out << " " << line }

    result = out.sub(/\n+\z/, "")
    result.empty? ? NO_CHANGE : result
  end

  def truncate_preview(diff, max_bytes)
    return [diff, false] if max_bytes <= 0 || diff.bytesize <= max_bytes

    truncated = trim_to_valid_utf8(diff.byteslice(0, max_bytes))
    if (newline = truncated.rindex("\n"))&.positive?
      truncated = truncated[0...newline]
    end
    truncated = truncated.sub(/\n+\z/, "")
    if truncated.empty?
      truncated = trim_to_valid_utf8(diff.byteslice(0, max_bytes)).sub(/\n+\z/, "")
    end
    [truncated, true]
  end

  def trim_to_valid_utf8(str)
    str = str.dup.force_encoding(Encoding::UTF_8)
    str = str.byteslice(0, str.bytesize - 1).to_s.force_encoding(Encoding::UTF_8) until str.valid_encoding? || str.empty?
    str
  end

  def display_path(path)
    display = path.to_s.tr("\\", "/").sub(%r{\A/+}, "")
    display.empty? ? "file" : display
  end
end
