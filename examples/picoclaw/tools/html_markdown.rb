# frozen_string_literal: true

require "cgi"
require "uri"

# HtmlMarkdown — port of picoclaw's pkg/utils/markdown.go (HtmlToMarkdown).
#
# Go walks a full html5lib tree; Ruby has no stdlib HTML parser, so this file
# pairs the converter with a small tolerant DOM builder (void elements,
# raw-text elements, comments/doctype skipped, entities unescaped). Output
# matches upstream on well-formed markup; on malformed markup Go's html5
# error-recovery may produce a different tree — the one known divergence.
module HtmlMarkdown
  Node = Struct.new(:type, :name, :attrs, :children, :parent, :text) do
    def element? = type == :element
    def text? = type == :text
    def attr(key) = attrs.find { |k, _| k == key }&.last.to_s
  end

  VOID_ELEMENTS = %w[area base br col embed hr img input link meta param source track wbr].freeze
  RAW_TEXT_ELEMENTS = %w[script style textarea title].freeze

  # Minimal tolerant DOM builder.
  class Dom
    def self.parse(html)
      root = Node.new(:document, nil, [], [], nil, nil)
      stack = [root]
      scanner = html.to_s
      pos = 0
      while pos < scanner.length
        rest = scanner[pos..]
        if rest.start_with?("<!--")
          close = scanner.index("-->", pos + 4) || scanner.length
          pos = [close + 3, scanner.length].min
        elsif rest.start_with?("<!") # doctype / declarations
          close = scanner.index(">", pos + 2) || scanner.length - 1
          pos = close + 1
        elsif scanner.getbyte(pos) == 60 # "<"
          if (m = rest.match(%r{\A</\s*([a-zA-Z][a-zA-Z0-9-]*)\s*>}))
            name = m[1].downcase
            # close the nearest matching open element; ignore stray closers
            idx = stack.rindex { |n| n.element? && n.name == name }
            stack = stack[0...idx] if idx && idx >= 1
            pos += m[0].length
          elsif (m = rest.match(/\A<([a-zA-Z][a-zA-Z0-9-]*)((?:\s+[^<>]*?)?)\s*(\/?)>/))
            name = m[1].downcase
            attrs = parse_attrs(m[2].to_s)
            node = Node.new(:element, name, attrs, [], stack.last, nil)
            stack.last.children << node
            open_end = pos + m[0].length
            if RAW_TEXT_ELEMENTS.include?(name) && m[3] != "/"
              close = scanner.index(%r{</\s*#{Regexp.escape(name)}\s*>}i, open_end)
              raw_end = close || scanner.length
              if raw_end > open_end
                node.children << Node.new(:text, nil, [], [], node, CGI.unescapeHTML(scanner[open_end...raw_end]))
              end
              pos = close ? scanner.index(">", close) + 1 : scanner.length
            else
              stack << node unless VOID_ELEMENTS.include?(name) || m[3] == "/"
              pos = open_end
            end
          else
            stack.last.children << Node.new(:text, nil, [], [], stack.last, "<")
            pos += 1
          end
        else
          stop = scanner.index(/</, pos) || scanner.length
          stack.last.children << Node.new(:text, nil, [], [], stack.last, CGI.unescapeHTML(scanner[pos...stop]))
          pos = stop
        end
      end
      root
    end

    def self.parse_attrs(str)
      attrs = []
      scanner = str.strip
      until scanner.empty?
        if (m = scanner.match(/\A([^\s=\/"']+)\s*=\s*"([^"]*)"/))
          attrs << [m[1].downcase, CGI.unescapeHTML(m[2])]
        elsif (m = scanner.match(/\A([^\s=\/"']+)\s*=\s*'([^']*)'/))
          attrs << [m[1].downcase, CGI.unescapeHTML(m[2])]
        elsif (m = scanner.match(/\A([^\s=\/"']+)\s*=\s*([^\s>]+)/))
          attrs << [m[1].downcase, CGI.unescapeHTML(m[2])]
        elsif (m = scanner.match(/\A([^\s=\/"']+)/))
          attrs << [m[1].downcase, ""]
        end
        scanner = scanner[m[0].length..].to_s.strip
      end
      attrs
    end
  end

  SKIP_TAGS = %w[script style head noscript template nav footer aside header form dialog].freeze
  UNLIKELY_KEYWORDS = %w[menu nav footer sidebar cookie banner sponsor advert popup modal newsletter share social].freeze

  RE_SPACES = /[ \t]+/
  RE_NEWLINES = /\n{3,}/
  RE_EMPTY_LIST_ITEM = /^[-*]\s*$/
  RE_IMAGE_ONLY_LINK = %r{\[!\[\]\(<[^>]*>\)\]\(<[^>]*>\)}
  RE_EMPTY_HEADER = /^\#{1,6}\s*$/
  RE_LEADING_LINE_SPACE = /^([ \t])([^ \t\n])/

  def self.convert(html_str)
    doc = Dom.parse(html_str)
    converter = Converter.new
    converter.walk(doc)
    res = converter.output

    res = res.gsub(RE_IMAGE_ONLY_LINK, "")
    res = res.gsub(RE_EMPTY_LIST_ITEM, "")
    res = res.gsub(RE_EMPTY_HEADER, "")

    lines = res.split("\n").map do |line|
      line = line.sub(/[ \t]+\z/, "")
      clean = line.strip
      clean = "" if ["[](</>)", "[](#)", "-"].include?(clean)
      clean.empty? ? "" : line
    end
    res = lines.join("\n")
    res = res.strip.gsub(RE_NEWLINES, "\n\n")
    # Strip a single leading space from lines that are not list indentation.
    res.gsub(RE_LEADING_LINE_SPACE, '\2')
  end

  class Converter
    def initialize
      @stack = [+""]
      @link_hrefs = []
      @link_states = []
      @emph_stack = []
      @ol_counters = []
      @in_pre = false
      @list_depth = 0
    end

    def output = @stack.first

    def write(str) = @stack.last << str
    def push_buf = @stack.push(+"")
    def pop_buf = @stack.pop

    def walk(node)
      if node.element?
        return if SKIP_TAGS.include?(node.name)
        return if unlikely_node?(node)
      end

      if node.text?
        text = node.text
        unless @in_pre
          text = text.gsub("\n", " ").gsub(RE_SPACES, " ")
        end
        write(text) unless text.empty?
        return
      end

      if node.element?
        open_tag(node)
      else
        node.children.each { |child| walk(child) }
        return
      end

      unless @skip_children
        node.children.each { |child| walk(child) }
      end
      @skip_children = false

      close_tag(node) if node.element?
    end

    private

    def open_tag(node)
      case node.name
      when "b", "strong" then @emph_stack.push("**") && push_buf
      when "i", "em" then @emph_stack.push("*") && push_buf
      when "del", "s" then @emph_stack.push("~~") && push_buf
      when "a"
        href = normalize_attr(node.attr("href"))
        href = "#" if !href.empty? && !safe_href?(href)
        has_href = !href.empty?
        @link_states.push(has_href)
        if has_href
          @link_hrefs.push(href)
          push_buf
        end
      when "h1" then write("\n\n# ")
      when "h2" then write("\n\n## ")
      when "h3" then write("\n\n### ")
      when "h4" then write("\n\n#### ")
      when "h5" then write("\n\n##### ")
      when "h6" then write("\n\n###### ")
      when "p" then write("\n\n")
      when "br" then write("\n")
      when "hr" then write("\n\n---\n\n")
      when "ol"
        @ol_counters.push(1)
        write("\n") if @list_depth.zero?
        @list_depth += 1
      when "ul"
        write("\n") if @list_depth.zero?
        @list_depth += 1
      when "li"
        write("\n")
        write("    " * (@list_depth - 1)) if @list_depth > 1
        if node.parent&.name == "ol" && @ol_counters.any?
          idx = @ol_counters[-1]
          write("#{idx}. ")
          @ol_counters[-1] += 1
        else
          write("- ")
        end
      when "pre"
        @in_pre = true
        write("\n\n```\n")
      when "code"
        write("`") unless @in_pre
      when "blockquote"
        push_buf
        node.children.each { |child| walk(child) }
        inner = pop_buf.strip
        quoted = inner.split("\n").map { |l| l.strip.empty? ? ">" : "> #{l}" }
        deduped = []
        quoted.each_with_index do |line, i|
          next if line == ">" && i.positive? && deduped.last == ">"

          deduped << line
        end
        write("\n\n#{deduped.join("\n")}\n\n")
        @skip_children = true
      when "img"
        src = normalize_attr(node.attr("src"))
        src = normalize_attr(node.attr("data-src")) if src.empty?
        if src.empty?
          @skip_children = true
          return
        end
        alt = escape_md_alt(normalize_attr(node.attr("alt")))
        write("![#{alt}](#{src})") if safe_image_src?(src)
        @skip_children = true
      end
    end

    def close_tag(node)
      case node.name
      when "b", "strong", "i", "em", "del", "s"
        return if @emph_stack.empty?

        marker = @emph_stack.pop
        inner = pop_buf.to_s.strip
        write("#{marker}#{inner}#{marker}") unless inner.empty?
      when "a"
        return if @link_states.empty?

        has_href = @link_states.pop
        return unless has_href

        href = @link_hrefs.pop
        inner = pop_buf.to_s.strip
        if inner.include?("\n")
          lines = inner.split("\n")
          linked = false
          lines = lines.map do |line|
            clean = line.strip
            if !clean.empty? && !clean.start_with?("![") && !linked
              linked = true
              "[#{clean}](#{href})"
            else
              line
            end
          end
          write(lines.join("\n"))
        else
          write("[#{inner}](#{href})")
        end
      when "h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "section", "article",
           "header", "footer", "aside", "nav", "figure"
        write("\n")
      when "ol"
        @list_depth -= 1
        @ol_counters.pop if @ol_counters.any?
        write("\n") if @list_depth.zero?
      when "ul"
        @list_depth -= 1
        write("\n") if @list_depth.zero?
      when "pre"
        @in_pre = false
        write("\n```\n\n")
      when "code"
        write("`") unless @in_pre
      end
    end

    def unlikely_node?(node)
      class_id = "#{node.attr("class")} #{node.attr("id")}".downcase
      return false if class_id == " "
      return false if class_id.include?("article") || class_id.include?("main") || class_id.include?("content")

      UNLIKELY_KEYWORDS.any? { |kw| class_id.include?(kw) }
    end

    def safe_href?(href)
      lower = href.to_s.strip.downcase
      return false if lower.start_with?("javascript:", "vbscript:", "data:")

      scheme = begin
        URI.parse(href.strip).scheme
      rescue URI::InvalidURIError
        return false
      end
      scheme = scheme.to_s.downcase
      scheme.empty? || %w[http https mailto].include?(scheme)
    end

    def safe_image_src?(src)
      return true if src.to_s.strip.downcase.start_with?("data:image/")

      safe_href?(src)
    end

    def escape_md_alt(str)
      str.gsub("\\", "\\\\").gsub("[", "\\[").gsub("]", "\\]")
    end

    def normalize_attr(val)
      val.to_s.delete("\n\r\t").strip
    end
  end
end
