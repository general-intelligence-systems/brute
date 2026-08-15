# frozen_string_literal: true

require "pathname"
require_relative "threat_patterns"

module Hermes
  # Context-file discovery and loading — port of the hermes-agent machinery in
  # agent/prompt_builder.py (load_soul_md, build_context_files_prompt and the
  # _load_* helpers).
  #
  # Priority (first found wins — only ONE project context type is loaded):
  #   1. .hermes.md / HERMES.md  (walk to git root)
  #   2. AGENTS.md / agents.md   (merged chain: git root → cwd, deduplicated)
  #   3. CLAUDE.md / claude.md   (cwd only)
  #   4. .cursorrules / .cursor/rules/*.mdc  (cwd only)
  #
  # SOUL.md is independent: loaded for the identity slot, and included in the
  # project-context block only when it wasn't used as identity.
  #
  # Every file is BOM-stripped, threat-scanned (context scope — a hit becomes
  # a [BLOCKED: …] placeholder, because the content enters the system prompt
  # verbatim), and capped (default 20,000 chars).
  module ContextFiles
    DEFAULT_MAX_CHARS = 20_000

    module_function

    # SOUL.md from the workspace — the agent identity (slot #1).
    # Returns nil when absent/empty.
    def load_soul(dir:, max_chars: DEFAULT_MAX_CHARS)
      path = File.join(dir, "SOUL.md")
      return nil unless File.exist?(path)

      content = File.read(path, encoding: Encoding::UTF_8).strip
      return nil if content.empty?

      content = scan(content, "SOUL.md")
      truncate(content, "SOUL.md", max_chars: max_chars, read_path: path)
    rescue SystemCallError, IOError
      nil
    end

    # The full project-context block ("" when nothing found).
    def build_prompt(cwd:, skip_soul: false, max_chars: DEFAULT_MAX_CHARS)
      cwd = File.expand_path(cwd)
      sections = []

      project =
        load_hermes_md(cwd, max_chars) ||
        load_agents_md(cwd, max_chars) ||
        load_claude_md(cwd, max_chars) ||
        load_cursorrules(cwd, max_chars)
      sections << project if project

      unless skip_soul
        soul = load_soul(dir: soul_home(cwd), max_chars: max_chars)
        sections << soul if soul
      end

      return "" if sections.empty?

      "# Project Context\n\nThe following project context files have been loaded and should be followed:\n\n" +
        sections.join("\n")
    end

    # SOUL.md lives at the workspace root in this port (no HERMES_HOME).
    def soul_home(cwd)
      cwd
    end

    # .hermes.md / HERMES.md — walk from cwd up to the git root.
    def load_hermes_md(cwd, max_chars)
      dir = cwd
      loop do
        %w[.hermes.md HERMES.md].each do |name|
          path = File.join(dir, name)
          next unless File.exist?(path)

          content = File.read(path, encoding: Encoding::UTF_8).strip
          return nil if content.empty?

          content = strip_frontmatter(content)
          rel = begin
            Pathname.new(path).relative_path_from(Pathname.new(cwd)).to_s
          rescue ArgumentError
            name
          end
          section = "## #{rel}\n\n#{scan(content, rel)}"
          return truncate(section, name, max_chars: max_chars, read_path: path)
        end
        break if dir == git_root(cwd) || dir == "/"

        dir = File.dirname(dir)
      end
      nil
    rescue SystemCallError, IOError
      nil
    end

    # AGENTS.md / agents.md — merged chain from git root down to cwd.
    # Each directory contributes its file as a provenance-labelled section;
    # identical content along the chain is deduplicated.
    def load_agents_md(cwd, max_chars)
      chain = directory_chain(cwd)
      sections = []
      seen = []
      chain.each do |dir|
        %w[AGENTS.md agents.md].each do |name|
          path = File.join(dir, name)
          next unless File.exist?(path)

          content = File.read(path, encoding: Encoding::UTF_8).strip
          next if content.empty?
          break if seen.include?(content) # identical copy along the chain

          seen << content
          label = dir == cwd ? name : Pathname.new(path).relative_path_from(Pathname.new(cwd)).to_s
          section = "## #{label}\n\n#{scan(content, label)}"
          sections << truncate(section, label, max_chars: max_chars, read_path: path)
          break # first name match wins per directory
        end
      end
      return nil if sections.empty?
      return sections.first if sections.size == 1

      merged = sections.join("\n\n")
      truncate(merged, "AGENTS.md", max_chars: max_chars, read_path: nil)
    rescue SystemCallError, IOError
      nil
    end

    # CLAUDE.md / claude.md — cwd only.
    def load_claude_md(cwd, max_chars)
      %w[CLAUDE.md claude.md].each do |name|
        path = File.join(cwd, name)
        next unless File.exist?(path)

        content = File.read(path, encoding: Encoding::UTF_8).strip
        next if content.empty?

        section = "## #{name}\n\n#{scan(content, name)}"
        return truncate(section, name, max_chars: max_chars, read_path: path)
      end
      nil
    rescue SystemCallError, IOError
      nil
    end

    # .cursorrules / .cursor/rules/*.mdc — cwd only.
    def load_cursorrules(cwd, max_chars)
      path = File.join(cwd, ".cursorrules")
      if File.exist?(path)
        content = File.read(path, encoding: Encoding::UTF_8).strip
        unless content.empty?
          section = "## .cursorrules\n\n#{scan(content, '.cursorrules')}"
          return truncate(section, ".cursorrules", max_chars: max_chars, read_path: path)
        end
      end

      rules_dir = File.join(cwd, ".cursor", "rules")
      if Dir.exist?(rules_dir)
        files = Dir[File.join(rules_dir, "*.mdc")].sort
        unless files.empty?
          sections = files.map do |f|
            content = File.read(f, encoding: Encoding::UTF_8).strip
            next nil if content.empty?

            "## #{File.basename(f)}\n\n#{scan(content, File.basename(f))}"
          end.compact
          unless sections.empty?
            return truncate(sections.join("\n\n"), ".cursor/rules", max_chars: max_chars, read_path: nil)
          end
        end
      end
      nil
    rescue SystemCallError, IOError
      nil
    end

    # Directories to check for AGENTS.md: git root first, cwd last.
    def directory_chain(cwd)
      root = git_root(cwd)
      return [cwd] if root.nil? || root == cwd

      chain = []
      dir = cwd
      chain.unshift(dir) until dir == root || (dir = File.dirname(dir)) == dir
      chain.unshift(root) unless chain.include?(root)
      chain
    end

    def git_root(start)
      dir = File.expand_path(start)
      loop do
        return dir if Dir.exist?(File.join(dir, ".git")) || File.exist?(File.join(dir, ".git"))
        return nil if dir == "/"

        dir = File.dirname(dir)
      end
    end

    # BOM strip, then context-scope threat scan. A finding becomes a
    # [BLOCKED: …] placeholder — the file would enter the system prompt
    # verbatim and the user has no chance to intervene.
    def scan(content, filename)
      content = content.sub(/\A\uFEFF/, "")
      findings = ThreatPatterns.scan_for_threats(content, scope: "context")
      return content if findings.empty?

      "[BLOCKED: #{filename} contained potential prompt injection (#{findings.join(', ')}). Content not loaded.]"
    end

    def truncate(content, name, max_chars:, read_path:)
      return content if content.length <= max_chars

      "#{content[0, max_chars]}\n\n[... #{name} truncated at #{max_chars} chars" \
        "#{read_path ? " — read #{read_path} for the full file" : ""}]"
    end

    def strip_frontmatter(content)
      content.sub(/\A---\n.*?\n---\n?/m, "")
    end
  end
end
