# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../path_guards"

module HermesTools
  # patch — edit files. Port of hermes-agent tools/file_tools.py patch_tool +
  # tools/patch_parser.py (V4A format, fuzzy application).
  #
  #   mode=replace: find-and-swap old_string → new_string in one file
  #                 (ambiguity refused unless replace_all).
  #   mode=patch:   a V4A multi-file patch:
  #                   *** Begin Patch
  #                   *** Update File: path
  #                   @@ optional context hint @@
  #                    context line (space prefix)
  #                   -removed line
  #                   +added line
  #                   *** Add File: path        (every line '+'-prefixed)
  #                   *** Delete File: path
  #                   *** Move File: old -> new
  #                   *** End Patch
  #   V4A header paths come from patch CONTENT (attacker-influenceable), so
  #   '..' traversal is rejected there. Update hunks apply via fuzzy
  #   find-and-replace (exact → whitespace-tolerant), with the @@ hint as a
  #   fallback anchor.
  class Patch < Brute::Tool
    description "Patch a file using replace mode (old_string → new_string) or V4A multi-file patch mode."
    params({
      "type" => "object",
      "properties" => {
        "mode" => { "type" => "string", "enum" => %w[replace patch], "default" => "replace" },
        "path" => { "type" => "string", "description" => "File to patch (replace mode)" },
        "old_string" => { "type" => "string", "description" => "Text to find (replace mode)" },
        "new_string" => { "type" => "string", "description" => "Replacement text (replace mode; empty deletes the match)" },
        "replace_all" => { "type" => "boolean", "default" => false },
        "patch" => { "type" => "string", "description" => "The V4A patch text (patch mode)" },
      },
      "required" => [],
    })

    def name = "patch"

    def execute(mode: "replace", path: nil, old_string: nil, new_string: nil,
                replace_all: false, patch: nil, **_rest)
      case mode
      when "replace"
        replace_mode(path, old_string, new_string, replace_all)
      when "patch"
        v4a_mode(patch)
      else
        err("unknown mode '#{mode}'. Use replace or patch.")
      end
    end

    private

    # -- replace mode -----------------------------------------------------------

    def replace_mode(path, old_string, new_string, replace_all)
      return err("path is required for replace mode") if path.to_s.empty?
      return err("old_string is required") if old_string.to_s.empty?
      return err("new_string is required (use empty string to delete the match)") if new_string.nil?

      guard = Hermes::PathGuards.check(path)
      return err(guard) if guard
      return err("File not found: #{path}") unless File.exist?(path)

      body = File.read(path, encoding: Encoding::UTF_8)
      return err("old_string not found in #{path}") unless body.include?(old_string)

      occurrences = body.scan(old_string).size
      if !replace_all && occurrences > 1
        return err("old_string matches #{occurrences} times in #{path} — be more specific or pass replace_all=true.")
      end

      updated = replace_all ? body.gsub(old_string) { new_string } : body.sub(old_string) { new_string }
      atomic_write(path, updated)
      JSON.dump("success" => true, "path" => path, "replacements" => replace_all ? occurrences : 1)
    end

    # -- V4A mode ---------------------------------------------------------------

    def v4a_mode(patch_text)
      return err("patch is required for patch mode") if patch_text.to_s.strip.empty?

      operations, parse_error = parse_v4a(patch_text)
      return err("V4A parse error: #{parse_error}") if parse_error
      return err("V4A patch contained no operations") if operations.empty?

      # Traversal + sensitive-path checks on every header path (both Move endpoints).
      operations.each do |op|
        [op[:path], op[:new_path]].compact.each do |p|
          if Hermes::PathGuards.traversal?(p)
            return err("V4A patch header contains '..' traversal: '#{p}'. Use a cwd-relative path (no '..') or an absolute path.")
          end
          guard = Hermes::PathGuards.check(p)
          return err(guard) if guard
        end
      end

      applied = []
      operations.each do |op|
        result = apply_operation(op)
        return err("V4A #{op[:type]} #{op[:path]} failed: #{result}") unless result == true

        applied << "#{op[:type]} #{op[:path]}"
      end

      JSON.dump("success" => true, "applied" => applied)
    end

    def parse_v4a(text)
      lines = text.lines.map(&:chomp)
      return [nil, "missing *** Begin Patch"] unless lines.first&.match?(/^\*\*\*\s*Begin\s+Patch/)

      operations = []
      current = nil
      i = 1
      while i < lines.size
        line = lines[i]
        case line
        when /^\*\*\*\s*End\s+Patch/
          break
        when /^\*\*\*\s*Update\s+File:\s*(.+)$/
          operations << current if current
          current = { type: "update", path: $1.strip, hunks: [] }
        when /^\*\*\*\s*Add\s+File:\s*(.+)$/
          operations << current if current
          current = { type: "add", path: $1.strip, content_lines: [] }
        when /^\*\*\*\s*Delete\s+File:\s*(.+)$/
          operations << current if current
          current = { type: "delete", path: $1.strip }
        when /^\*\*\*\s*Move\s+File:\s*(.+?)\s*->\s*(.+)$/
          operations << current if current
          operations << { type: "move", path: $1.strip, new_path: $2.strip }
          current = nil
        when /^@@\s*(.+?)\s*@@/
          return [nil, "@@ hint outside an Update File block"] unless current && current[:type] == "update"

          current[:hunks] << { hint: $1.strip, lines: [] }
        else
          if current && current[:type] == "add" && line.start_with?("+")
            current[:content_lines] << line[1..]
          elsif current && current[:type] == "update" && line =~ /\A[ \-+]/
            current[:hunks] << { hint: nil, lines: [] } if current[:hunks].empty? || current[:hunks].last[:hint]
            current[:hunks].last[:lines] << { prefix: line[0], content: line[1..] }
          elsif line.strip.empty?
            # blank separator line — ignore between blocks
          else
            return [nil, "unparseable line #{i + 1}: #{line.inspect}"]
          end
        end
        i += 1
      end
      operations << current if current
      [operations.compact, nil]
    end

    def apply_operation(op)
      case op[:type]
      when "add"
        return "file already exists: #{op[:path]}" if File.exist?(op[:path])

        FileUtils.mkdir_p(File.dirname(op[:path]))
        atomic_write(op[:path], (op[:content_lines] || []).join("\n") + "\n")
        true
      when "delete"
        return "file not found: #{op[:path]}" unless File.exist?(op[:path])

        File.delete(op[:path])
        true
      when "move"
        return "file not found: #{op[:path]}" unless File.exist?(op[:path])

        FileUtils.mkdir_p(File.dirname(op[:new_path]))
        FileUtils.mv(op[:path], op[:new_path])
        true
      when "update"
        return "file not found: #{op[:path]}" unless File.exist?(op[:path])

        body = File.read(op[:path], encoding: Encoding::UTF_8)
        op[:hunks].each do |hunk|
          search = []
          replace = []
          hunk[:lines].each do |l|
            case l[:prefix]
            when " " then search << l[:content]; replace << l[:content]
            when "-" then search << l[:content]
            when "+" then replace << l[:content]
            end
          end
          next if search == replace # context-only hunk

          body, ok = fuzzy_replace(body, search.join("\n"), replace.join("\n"), hint: hunk[:hint])
          return "no match for hunk in #{op[:path]} (hint: #{hunk[:hint]})" unless ok
        end
        atomic_write(op[:path], body)
        true
      end
    end

    # Exact match first, then whitespace-tolerant (each line stripped). The
    # @@ hint, when present, anchors the search window as a fallback.
    def fuzzy_replace(body, search, replacement, hint: nil)
      return [body, true] if search.empty?

      if body.include?(search)
        return [body.sub(search) { replacement }, true]
      end

      norm = ->(s) { s.lines.map(&:strip).join("\n") }
      body_lines = body.lines
      search_lines = norm.call(search).lines
      (0..(body_lines.size - search_lines.size)).each do |start|
        window = body_lines[start, search_lines.size]
        if norm.call(window.join) == norm.call(search)
          # replace the matched window with the replacement (line-preserving)
          before = body_lines[0...start]
          after = body_lines[(start + search_lines.size)..] || []
          return [(before + [replacement + "\n"] + after).join, true]
        end
      end

      if hint && (pos = body.index(hint))
        window_start = body[0..pos].lines.size - 1
        window = body_lines[window_start, search_lines.size + 5] || []
        if norm.call(window.first(search_lines.size).join) == norm.call(search)
          before = body_lines[0...window_start]
          after = body_lines[(window_start + search_lines.size)..] || []
          return [(before + [replacement + "\n"] + after).join, true]
        end
      end

      [body, false]
    end

    def atomic_write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.write(tmp, content, encoding: Encoding::UTF_8)
      File.rename(tmp, path)
    end

    def err(message)
      JSON.dump("error" => message)
    end
  end
end
