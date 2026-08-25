# frozen_string_literal: true

require "rdoc"
require "ripper"
require "fileutils"
require "json"

# This generator reaches past RDoc's generator interface into its markup
# formatters and cross-reference resolver, which are documented but not
# guaranteed stable across majors — `CrossReference#resolve` changed arity in
# 8.0, and `ToMarkdown` gained the handler this subclasses. Failing loudly here
# beats a silent build that drops every cross-reference.
unless RDoc::VERSION.start_with?("8.")
  raise "docs/bin/rdoc_starlight.rb targets RDoc 8.x, found #{RDoc::VERSION}"
end

##
# Renders RDoc comment markup as Markdown with cross-references resolved to
# Starlight routes.
#
# +RDoc::Markup::ToMarkdown+ has no cross-reference handling — it descends from
# +ToRdoc+, which predates it. The mechanism lives in +ToHtmlCrossref+, which
# registers a regexp handling for the +CROSSREF+ pattern and resolves the match
# against the store. This does the same, but emits a Markdown link pointing at
# the slug the generator will write the target to, rather than an +.html+ path.
class RDoc::Markup::ToMarkdownCrossref < RDoc::Markup::ToMarkdown
  # +context+ is the class or module the comment belongs to, which is what
  # relative references like +#call+ resolve against. +resolver+ maps a
  # resolved code object to a site-absolute path, or nil when the target is
  # not part of the generated reference.
  def initialize(context:, resolver:, hyperlink_all: false)
    @hyperlink_all = hyperlink_all

    super()

    @context = context
    @resolver = resolver
    @cross_reference = RDoc::CrossReference.new(context)

    # Registered here rather than by overriding
    # `init_link_notation_regexp_handlings`, which looks like the natural hook
    # but is only ever called by `ToHtml` — an override on this branch of the
    # hierarchy is never invoked.
    crossref_re =
      if @hyperlink_all
        RDoc::CrossReference::ALL_CROSSREF_REGEXP
      else
        RDoc::CrossReference::CROSSREF_REGEXP
      end

    @markup.add_regexp_handling crossref_re, :CROSSREF
  end

  ##
  # Emits verbatim blocks as fenced code rather than the four-space indent
  # `ToMarkdown` uses. The indent form is valid Markdown but carries no
  # language, so Expressive Code renders it unhighlighted.
  def accept_verbatim(verbatim)
    body = verbatim.text.rstrip

    @res << "\n```#{verbatim_language(verbatim, body)}\n#{body}\n```\n\n"
  end

  ##
  # Picks the fence language for a verbatim block.
  #
  # +Verbatim#ruby?+ only reports what an explicit +:format:+ directive set, so
  # it is almost never true for an ordinary indented example. Parsing the block
  # is the reliable test, and it is the same question: if Ripper accepts it, it
  # is Ruby.
  def verbatim_language(verbatim, body)
    return "ruby" if verbatim.ruby?
    return "sh" if body.match?(/\A\s*[$%#]\s+\S/)

    # `...` as an elided body is common in examples and is not itself valid in
    # every position, so it is stood in for before parsing.
    probe = body.gsub(/^(\s*)\.\.\.\s*$/, "\\1nil")

    begin
      Ripper.sexp(probe) ? "ruby" : ""
    rescue StandardError
      ""
    end
  end

  ##
  # RDoc markup spells a link +label[url]+, which collides with Ruby's own
  # subscript syntax: a comment mentioning +env[:messages]+ parses as a link
  # labelled "env" pointing at ":messages". RDoc's +parse_url+ then assumes any
  # unrecognised target is an +http+ URL, so the link is emitted rather than
  # rejected — Darkfish has the same behaviour.
  #
  # Anything that is not recognisably a URL is therefore restored to the
  # subscript it was written as, and set in code.
  URL_LIKE = %r{\A(?:https?://|ftp://|mailto:|//|www\.|[/#])}i

  def handle_TIDYLINK(label_part, url)
    return super if link_target?(url)

    # Rebuilt as the subscript expression it was written as. The label is a
    # node list rather than a string, so it has to be walked to be emitted.
    emit_inline("`")
    traverse_inline_nodes(label_part)
    emit_inline("[#{url}]`")
  end

  # The same guard for the footnote/label path, which routes through `gen_url`
  # rather than `handle_TIDYLINK`.
  def gen_url(url, text)
    return super if link_target?(url)

    "`#{text}[#{url}]`"
  end

  def link_target?(url)
    url.match?(URL_LIKE) || url.start_with?("rdoc-")
  end

  ##
  # Resolves a +Foo::Bar#baz+ style reference to a Markdown link.
  #
  # The pattern matches any capitalised word, so most of what arrives here is
  # ordinary prose — a sentence starting "Base class for..." offers +Base+ as a
  # candidate. Anything that does not resolve is therefore returned untouched,
  # as prose, not marked up as code.
  def handle_regexp_CROSSREF(name)
    # A reference the author escaped with a leading backslash.
    return name[1..] if name.start_with?("\\")

    # Guards carried over from `ToHtmlCrossref`. The lowercase one matters
    # most: without it every bare `new`, `call` or `each` in prose becomes a
    # link to whatever method happens to share the name.
    return name if name =~ /@[\w-]+\.[\w-]/ # labels that look like emails
    return name if !@hyperlink_all && name =~ /\A[a-z]*\z/

    # Returns nil when the name does not resolve, or resolves to something
    # undocumented.
    ref = @cross_reference.resolve name
    return name unless ref

    path = @resolver.call(ref)
    return name unless path

    "[`#{name.delete_prefix("::")}`](#{path})"
  end
end

##
# Generates Astro Starlight content from an RDoc store.
#
# This exists instead of a themed HTML generator because the reference has to
# live *inside* the docs site rather than beside it. Static HTML dropped into
# `public/` would carry its own header, sidebar, search and theme toggle, and —
# decisively — Pagefind indexes only pages carrying `data-pagefind-body`, which
# Starlight puts on its own pages alone. Reference pages emitted as content
# collection entries get the site's chrome, search, theme and table of contents
# for free, and stay in step with them.
#
# Output is plain Markdown rather than MDX so the pages stay cheap to build and
# readable as source.
class RDoc::Generator::Starlight
  RDoc::RDoc.add_generator self

  DESCRIPTION = "Astro Starlight Markdown generator for the brute docs site"

  ##
  # Route prefix within the docs site, and the directory under
  # `src/content/docs` that pages are written to.
  SECTION = "reference"

  attr_reader :store, :options

  def initialize(store, options)
    @store = store
    @options = options
    # Site base path (`/brute`), which Markdown links must carry explicitly.
    # Sidebar entries must *not* — Starlight applies the base to those itself.
    @base = ENV.fetch("STARLIGHT_BASE", "").chomp("/")
    @output_dir = ENV.fetch("STARLIGHT_CONTENT_DIR")
    @sidebar_path = ENV.fetch("STARLIGHT_SIDEBAR_PATH")
  end

  def generate
    classes = store.all_classes_and_modules.select(&:display?).sort_by(&:full_name)

    # Built before any page is rendered: cross-reference resolution needs to
    # know every slug up front, since a comment on the first page may link to
    # the last.
    @slugs = classes.to_h { |klass| [klass.full_name, slug_for(klass.full_name)] }
    @anchors = build_anchors(classes)

    FileUtils.rm_rf @output_dir
    FileUtils.mkdir_p @output_dir

    classes.each { |klass| write_page klass }
    write_index classes
    write_sidebar classes

    warn "reference: #{classes.size} pages -> #{@output_dir}"
  end

  private

  ##
  # `Brute::MessageTransport` -> `brute/message-transport`.
  #
  # Namespace separators become path separators so the URLs mirror the constant
  # nesting, and camel case becomes hyphens so they read as slugs rather than
  # as run-together words (`BruteCLI` -> `brute-cli`, not `brutecli`).
  def slug_for(full_name)
    full_name.split("::").map { |part|
      part
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1-\2')
        .gsub(/([a-z\d])([A-Z])/, '\1-\2')
        .downcase
    }.join("/")
  end

  ##
  # Site-absolute path for a resolved code object, or nil when it is not part
  # of the reference. Method references land on their anchor within the page of
  # the class that defines them.
  def path_for(ref)
    case ref
    when RDoc::AnyMethod, RDoc::Attr
      parent = @slugs[ref.parent&.full_name]
      anchor = anchor_for(ref)
      parent && anchor && "#{@base}/#{SECTION}/#{parent}/##{anchor}"
    when RDoc::ClassModule
      slug = @slugs[ref.full_name]
      slug && "#{@base}/#{SECTION}/#{slug}/"
    when RDoc::Constant
      parent = @slugs[ref.parent&.full_name]
      anchor = anchor_for(ref)
      parent && anchor && "#{@base}/#{SECTION}/#{parent}/##{anchor}"
    end
  end

  ##
  # Port of github-slugger, which is what Astro uses to derive heading ids.
  # Cross-reference links have to agree with it exactly or they land nowhere,
  # including its de-duplication: a repeated slug gets `-1`, `-2` and so on in
  # document order. Ruby method names make that a live concern rather than a
  # theoretical one — `valid?`, `valid!` and `valid` all reduce to `valid`.
  class Slugger
    def initialize = @seen = Hash.new(0)

    def slug(text)
      base = text
        .downcase
        .gsub(/[^\p{Word}\- ]/u, "")
        .tr(" ", "-")

      # A name made entirely of punctuation (`[]`, `<=>`, `+`) slugs to
      # nothing; the counter suffix would then be the whole anchor.
      base = "method" if base.empty?

      count = @seen[base]
      @seen[base] += 1
      count.zero? ? base : "#{base}-#{count}"
    end
  end

  ##
  # Headings as rendered. Class methods carry `self.`, which is both how Ruby
  # spells them and enough to keep them from colliding with an instance method
  # of the same name.
  def heading_for(member)
    case member
    when RDoc::AnyMethod
      member.singleton ? "self.#{member.name}" : "##{member.name}"
    else
      member.name.to_s
    end
  end

  ##
  # Assigns every member of every class the anchor its heading will get.
  #
  # This has to run before any page is rendered: a comment on the first page
  # may cross-reference a method on the last, and the anchor depends on how
  # many earlier headings on *that* page slugged to the same string. Walking
  # members in exactly the order `render_page` emits them is what keeps the two
  # in agreement.
  def build_anchors(classes)
    classes.to_h do |klass|
      slugger = Slugger.new
      anchors = {}

      page_members(klass).each do |member|
        anchors[member] = slugger.slug(heading_for(member))
      end

      [klass.full_name, anchors]
    end
  end

  ##
  # Every member that gets a heading, in render order. Single source of truth
  # for both anchor assignment and page rendering.
  def page_members(klass)
    [
      *klass.constants.select(&:display?).sort_by(&:name),
      *klass.attributes.select(&:display?).sort_by(&:name),
      *sorted_methods(klass, singleton: true),
      *sorted_methods(klass, singleton: false),
    ]
  end

  def sorted_methods(klass, singleton:)
    klass.method_list
         .select { |m| m.display? && !!m.singleton == singleton }
         .sort_by { |m| m.name.to_s }
  end

  ##
  # Anchor for a member, looked up rather than recomputed.
  def anchor_for(member)
    @anchors.dig(member.parent&.full_name, member)
  end

  ##
  # Comments reach the store in three shapes: an +RDoc::Comment+ awaiting
  # parse, an already-merged +Document+ (which is what +ClassModule#comment+
  # returns when a constant is reopened across files), or a bare String. This
  # normalises all three to a Document, or nil when there is nothing to say.
  def as_document(comment, context)
    case comment
    when nil then nil
    when RDoc::Markup::Document
      comment.empty? ? nil : comment
    when RDoc::Comment
      comment.empty? ? nil : comment.parse
    when String
      return nil if comment.strip.empty?

      RDoc::Comment.new(comment, context).parse
    end
  end

  ##
  # Converts an RDoc comment to Markdown. Returns nil for an empty comment so
  # callers can decide how to mark the absence rather than emitting a blank.
  def markdown(comment, context)
    document = as_document(comment, context)
    return nil if document.nil?

    formatter = RDoc::Markup::ToMarkdownCrossref.new(
      context: context,
      resolver: method(:path_for),
    )

    text = document.accept(formatter).to_s.strip
    text.empty? ? nil : text
  end

  NOT_DOCUMENTED = "*Not documented.*"

  ##
  # First sentence of a comment, flattened for use as page description and
  # search snippet.
  def summary(klass)
    text = markdown(klass.comment, klass)
    return "#{klass.type == "class" ? "Class" : "Module"} #{klass.full_name}." unless text

    first = text.split(/\n\s*\n/).first.to_s.gsub(/\s+/, " ").strip
    first = plain_text(first)
    first = first.split(/(?<=\.)\s/).first.to_s
    first.length > 160 ? "#{first[0, 157].rstrip}..." : first
  end

  ##
  # Flattens the Markdown a summary may contain — links and code spans — to the
  # text they wrap. Frontmatter descriptions are rendered as attribute values
  # and search snippets, neither of which interprets markup.
  def plain_text(text)
    text
      .gsub(/\[`?([^\]`]+)`?\]\([^)]*\)/, '\\1') # [`Foo`](/path) -> Foo
      .gsub(/`([^`]+)`/, '\\1')
      .gsub(/\*\*?([^*]+)\*\*?/, '\\1')
  end

  def frontmatter(title:, description:)
    <<~YAML
      ---
      title: #{title.to_json}
      description: #{description.to_json}
      ---
    YAML
  end

  def write_page(klass)
    slug = @slugs[klass.full_name]
    path = File.join(@output_dir, "#{slug}.md")
    FileUtils.mkdir_p File.dirname(path)

    File.write path, render_page(klass)
  end

  def render_page(klass)
    out = +""
    out << frontmatter(title: klass.full_name, description: summary(klass))
    out << "\n"

    out << render_declaration(klass)

    body = markdown(klass.comment, klass)
    out << "\n#{body}\n" if body

    out << render_constants(klass)
    out << render_attributes(klass)
    out << render_methods(klass, singleton: true)
    out << render_methods(klass, singleton: false)
    out << render_source(klass)

    out
  end

  ##
  # The declaration block above the prose: the class or module as it would be
  # written, with its superclass and mixins.
  #
  # Rendered nested inside its namespace rather than as one qualified name,
  # which is not only how the source spells it but is what makes the page
  # findable: Pagefind does not produce a standalone token for the last segment
  # of a `Foo::Bar::Baz` chain, so a page whose only mention of `SlidingWindow`
  # is inside its qualified name cannot be found by that name. Written on its
  # own line it indexes as itself.
  def render_declaration(klass)
    *namespace, short = klass.full_name.split("::")

    signature = +"#{klass.type == "class" ? "class" : "module"} #{short}"

    if klass.type == "class"
      superklass = klass.superclass
      name = superklass.is_a?(RDoc::ClassModule) ? superklass.full_name : superklass.to_s
      # `Object` is the implicit default and says nothing worth a line.
      signature << " < #{relative_name(name, klass)}" unless name.empty? || name == "Object"
    end

    body = []
    klass.includes.each { |inc| body << "include #{relative_name(inc.full_name || inc.name, klass)}" }
    klass.extends.each { |ext| body << "extend #{relative_name(ext.full_name || ext.name, klass)}" }

    lines = [signature, *body.map { |line| "  #{line}" }, "end"]
    lines = ["module #{namespace.join("::")}", *lines.map { |l| "  #{l}" }, "end"] unless namespace.empty?

    "\n```ruby\n#{lines.join("\n")}\n```\n"
  end

  ##
  # Drops the leading namespace when it is the one we are already inside, so a
  # sibling reads as `Strategy` rather than
  # `Brute::Compaction::Middleware::Strategy`.
  def relative_name(name, klass)
    namespace = klass.full_name.split("::")[0..-2].join("::")
    return name if namespace.empty?

    name.delete_prefix("#{namespace}::")
  end

  def render_constants(klass)
    constants = klass.constants.select(&:display?).sort_by(&:name)
    return "" if constants.empty?

    out = +"\n## Constants\n"
    constants.each do |const|
      out << "\n### #{heading_for(const)}\n"
      out << "\n```ruby\n#{const.name} = #{const.value.to_s.strip}\n```\n" if const.value
      out << "\n#{markdown(const.comment, klass) || NOT_DOCUMENTED}\n"
    end
    out
  end

  def render_attributes(klass)
    attributes = klass.attributes.select(&:display?).sort_by(&:name)
    return "" if attributes.empty?

    out = +"\n## Attributes\n"
    attributes.each do |attr|
      access = { "R" => "read-only", "W" => "write-only", "RW" => "read/write" }[attr.rw.to_s.upcase]
      out << "\n### #{heading_for(attr)}\n"
      out << "\n`#{attr.name}` &mdash; #{access}\n" if access
      out << "\n#{markdown(attr.comment, klass) || NOT_DOCUMENTED}\n"
    end
    out
  end

  def render_methods(klass, singleton:)
    methods = sorted_methods(klass, singleton: singleton)
    return "" if methods.empty?

    out = +"\n## #{singleton ? "Class" : "Instance"} Methods\n"
    methods.each { |method| out << render_method(method, klass) }
    out
  end

  def render_method(method, klass)
    out = +"\n### #{heading_for(method)}\n"

    # `call_seq` is the author's explicit signature block when present; it is
    # authoritative because it documents overloads that the parsed arglist
    # cannot express.
    signatures = method.call_seq || method.arglists
    if signatures && !signatures.to_s.strip.empty?
      out << "\n```ruby\n#{signatures.to_s.strip}\n```\n"
    end

    visibility = method.visibility.to_s
    out << "\n*#{visibility}*\n" unless visibility == "public"

    out << "\n#{markdown(method.comment, klass) || NOT_DOCUMENTED}\n"

    aliases = method.aliases.map { |a| "`#{a.name}`" }
    out << "\nAlso aliased as: #{aliases.join(", ")}\n" unless aliases.empty?

    out
  end

  ##
  # Where the class is defined. Useful in a codebase where one constant is
  # commonly reopened across several files.
  def render_source(klass)
    files = klass.in_files.map(&:full_name).uniq.sort
    return "" if files.empty?

    "\n## Defined in\n\n#{files.map { |f| "- `#{f}`" }.join("\n")}\n"
  end

  def write_index(classes)
    out = +""
    out << frontmatter(
      title: "API Reference",
      description: "Generated reference for every public class and module in brute.",
    )

    out << "\nGenerated from the source with RDoc. "
    out << "#{classes.count { |c| c.type == "class" }} classes and "
    out << "#{classes.count { |c| c.type == "module" }} modules.\n"

    # Grouped by top-level namespace so the landing page mirrors the sidebar.
    classes.group_by { |klass| klass.full_name.split("::").first }
           .sort_by(&:first)
           .each do |namespace, members|
      out << "\n## #{namespace}\n\n"
      members.each do |klass|
        out << "- [`#{klass.full_name}`](#{@base}/#{SECTION}/#{@slugs[klass.full_name]}/) &mdash; #{summary(klass)}\n"
      end
    end

    File.write File.join(@output_dir, "index.md"), out
  end

  ##
  # Writes the sidebar as JSON for `astro.config.mjs` to import.
  #
  # Explicit entries rather than Starlight's `autogenerate`, because
  # autogenerate derives groups from directories and would render `Brute` the
  # module and `Brute/` the directory as two unrelated things. Grouping by
  # top-level namespace also keeps the tree to one level, which reads better
  # than the four-deep nesting the constant paths would otherwise produce.
  def write_sidebar(classes)
    groups = classes.group_by { |klass| klass.full_name.split("::").first }
                    .sort_by(&:first)
                    .map do |namespace, members|
      {
        label: namespace,
        collapsed: true,
        items: members.map do |klass|
          # Labelled with the name relative to the group, since the group
          # header already carries the namespace.
          { label: klass.full_name.delete_prefix("#{namespace}::"), slug: "#{SECTION}/#{@slugs[klass.full_name]}" }
        end,
      }
    end

    sidebar = [{ label: "Overview", slug: SECTION }, *groups]

    FileUtils.mkdir_p File.dirname(@sidebar_path)
    File.write @sidebar_path, "#{JSON.pretty_generate(sidebar)}\n"
  end
end
