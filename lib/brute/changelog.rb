# frozen_string_literal: true

require "date"

require "gem_kit"

module Brute
  # A parser and linter for CHANGELOG.md, which follows
  # [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
  #
  # The changelog is the one release artefact nothing else can regenerate, so
  # it is the one most easily forgotten. Making it machine-checkable turns
  # "did anyone write the changelog?" into a gate: `bin/lint-changelog`
  # validates the format, and `bin/release-gem` refuses to push a version that
  # has no section of its own.
  #
  #   changelog = Brute::Changelog.load
  #   changelog.problems              # => [] when the format is clean
  #   changelog.release_problems("4.1.0")
  #
  # The shape it expects:
  #
  #   # Changelog
  #
  #   ## [Unreleased]
  #
  #   ## [4.1.0] - 2026-08-20
  #
  #   ### Added
  #
  #   - Something that happened.
  #
  class Changelog
    # Deprecated. This moved out to the gem_kit-release gem, where the rest of
    # the release toolchain now lives — `gem kit changelog` is the CLI over it.
    # The implementation stays here, working, until the deadline.
    extend GemKit::Deprecate
    superseded_by "GemKit::Release::Changelog", "5.0"

    # The six change types Keep a Changelog defines. Anything else under a
    # version is a typo or an invention, and both are worth catching.
    SECTIONS = %w[Added Changed Deprecated Removed Fixed Security].freeze

    UNRELEASED       = "Unreleased"
    HEADING          = /\A##\s+\[([^\]]+)\](?:\s+-\s+(.*))?\s*\z/
    SUBHEADING       = /\A###\s+(.*?)\s*\z/
    BULLET           = /\A[-*]\s+\S/
    DATE             = /\A\d{4}-\d{2}-\d{2}\z/

    # One `## [...]` section of the file.
    Release = Struct.new(:version, :date, :line, :subsections, keyword_init: true) do
      def unreleased? = version == UNRELEASED
      def empty? = subsections.empty? || subsections.values.all?(&:empty?)
      def to_s = unreleased? ? "[#{version}]" : "[#{version}] - #{date}"
    end

    # Load the changelog sitting beside the gem (../../CHANGELOG.md).
    def self.load(path = File.expand_path("../../CHANGELOG.md", __dir__))
      new(File.exist?(path) ? File.read(path) : nil, path: path)
    end

    attr_reader :path, :releases

    # @parameter text [String, nil] the file's contents; nil means "no file".
    def initialize(text, path: "CHANGELOG.md")
      @path     = path
      @text     = text
      @releases = text ? parse(text) : []
    end

    def missing? = @text.nil?

    def unreleased = releases.find(&:unreleased?)

    def released = releases.reject(&:unreleased?)

    def find(version)
      target = Gem::Version.new(version.to_s)
      released.find { |release| Gem::Version.new(release.version) == target rescue false }
    end

    # Everything wrong with the file's *format*, as a list of human-readable
    # problems. Empty means it lints clean.
    def problems
      return ["#{path} does not exist"] if missing?

      [*header_problems, *heading_problems, *ordering_problems, *content_problems]
    end

    # Everything standing between this changelog and releasing `version`.
    # Format problems count: a file nobody can parse is not documentation.
    def release_problems(version)
      return problems unless problems.empty?

      release = find(version)
      return ["#{path} has no section for #{version} — run bin/update-changelog"] if release.nil?
      return ["#{path} section for #{version} is empty"] if release.empty?

      newest = released.first
      if newest && newest.version != release.version
        return ["#{path} lists #{newest.version} above #{version}; the release being cut must come first"]
      end

      []
    end

    private

      # Split the file into `## [...]` sections, recording each one's
      # `### Type` subsections and their top-level bullets.
      def parse(text)
        found   = []
        current = nil
        heading = nil

        text.each_line.with_index(1) do |line, number|
          case line
          when HEADING
            heading = nil
            current = Release.new(version: $1, date: $2&.strip, line: number, subsections: {})
            found << current
          when SUBHEADING
            next unless current

            heading = $1
            (current.subsections[heading] ||= [])
          when BULLET
            current.subsections[heading] << line.strip if current && heading
          end
        end

        found
      end

      def header_problems
        first = @text.each_line.find { |line| !line.strip.empty? }
        return [] if first&.strip == "# Changelog"

        ["#{path}:1 must start with the title `# Changelog`"]
      end

      def heading_problems
        problems = []

        @text.each_line.with_index(1) do |line, number|
          next unless line.start_with?("## ") && !line.start_with?("###")

          unless line =~ HEADING
            problems << "#{path}:#{number} malformed version heading: #{line.strip.inspect} " \
                        "(expected `## [Unreleased]` or `## [1.2.3] - YYYY-MM-DD`)"
            next
          end

          version, date = $1, $2&.strip
          next if version == UNRELEASED

          problems << "#{path}:#{number} #{version} has no date (expected `## [#{version}] - YYYY-MM-DD`)" if date.nil? || date.empty?
          problems << "#{path}:#{number} #{version} has a malformed date: #{date.inspect}" if date && !date.empty? && date !~ DATE
          problems << "#{path}:#{number} #{version} is not a valid version number" unless valid_version?(version)
        end

        problems + subheading_problems
      end

      def subheading_problems
        @text.each_line.with_index(1).filter_map do |line, number|
          next unless line.start_with?("### ")
          next if line =~ SUBHEADING && SECTIONS.include?($1)

          "#{path}:#{number} unknown section #{line.sub("###", "").strip.inspect} " \
            "(expected one of: #{SECTIONS.join(", ")})"
        end
      end

      def ordering_problems
        problems = []

        if unreleased && releases.first&.unreleased? == false
          problems << "#{path}:#{unreleased.line} [Unreleased] must be the first section"
        end

        seen = {}
        released.each do |release|
          if (first = seen[release.version])
            problems << "#{path}:#{release.line} duplicate section for #{release.version} (also at line #{first})"
          end
          seen[release.version] ||= release.line
        end

        versions = released.select { |release| valid_version?(release.version) }
        versions.each_cons(2) do |newer, older|
          next if Gem::Version.new(newer.version) > Gem::Version.new(older.version)

          problems << "#{path}:#{older.line} #{older.version} is listed below #{newer.version}; " \
                      "releases must run newest to oldest"
        end

        problems
      end

      def content_problems
        released.flat_map do |release|
          if release.subsections.empty?
            ["#{path}:#{release.line} #{release} has no #{SECTIONS.join("/")} section"]
          else
            release.subsections.filter_map do |heading, bullets|
              "#{path}:#{release.line} #{release} has an empty `### #{heading}` section" if bullets.empty?
            end
          end
        end
      end

      def valid_version?(version)
        Gem::Version.correct?(version)
      end
  end
end

__END__

describe "brute/changelog" do
  # These specs exercise a deprecated class on purpose; skip_during keeps the
  # warning out of the suite's output (see DEPRECATIONS.md).
  changelog = lambda do |body|
    Gem::Deprecate.skip_during { Brute::Changelog.new("# Changelog\n\n#{body}") }
  end

  good = <<~MD
    ## [Unreleased]

    ## [4.1.0] - 2026-08-20

    ### Added

    - A thing.

    ## [4.0.0] - 2026-08-01

    ### Removed

    - An older thing.
  MD

  it "parses sections, dates and bullets" do
    log = changelog.call(good)

    log.releases.map(&:version).should == ["Unreleased", "4.1.0", "4.0.0"]
    log.unreleased.should.be.kind_of?(Brute::Changelog::Release)
    log.released.first.date.should == "2026-08-20"
    log.released.first.subsections["Added"].should == ["- A thing."]
    log.find("4.0.0").subsections["Removed"].size.should == 1
  end

  it "lints a well-formed file clean and clears it for release" do
    log = changelog.call(good)

    log.problems.should == []
    log.release_problems("4.1.0").should == []
  end

  it "requires the `# Changelog` title" do
    Gem::Deprecate.skip_during do
      Brute::Changelog.new("## [1.0.0] - 2026-01-01\n\n### Added\n\n- x\n")
        .problems.first.should.match(/must start with the title/)
    end
  end

  it "reports a missing file" do
    log = Gem::Deprecate.skip_during { Brute::Changelog.new(nil, path: "nope.md") }
    log.missing?.should.be.true
    log.problems.first.should.match(/does not exist/)
  end

  it "rejects a malformed version heading" do
    changelog.call("## 1.0.0\n").problems.first.should.match(/malformed version heading/)
  end

  it "rejects an undated or badly dated release" do
    changelog.call("## [1.0.0]\n\n### Added\n\n- x\n").problems.first.should.match(/has no date/)
    changelog.call("## [1.0.0] - 20260101\n\n### Added\n\n- x\n").problems.first.should.match(/malformed date/)
  end

  it "rejects an unknown section type" do
    changelog.call("## [1.0.0] - 2026-01-01\n\n### Improved\n\n- x\n")
      .problems.first.should.match(/unknown section "Improved"/)
  end

  it "rejects an empty release and an empty subsection" do
    changelog.call("## [1.0.0] - 2026-01-01\n").problems.first.should.match(/has no Added/)
    changelog.call("## [1.0.0] - 2026-01-01\n\n### Added\n\n## [0.9.0] - 2026-01-01\n\n### Added\n\n- x\n")
      .problems.first.should.match(/empty `### Added` section/)
  end

  it "rejects duplicates and out-of-order releases" do
    body = "## [1.0.0] - 2026-01-02\n\n### Added\n\n- x\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- y\n"
    changelog.call(body).problems.first.should.match(/duplicate section for 1\.0\.0/)

    body = "## [1.0.0] - 2026-01-01\n\n### Added\n\n- x\n\n## [2.0.0] - 2026-01-02\n\n### Added\n\n- y\n"
    changelog.call(body).problems.first.should.match(/must run newest to oldest/)
  end

  it "requires [Unreleased] to come first" do
    body = "## [1.0.0] - 2026-01-01\n\n### Added\n\n- x\n\n## [Unreleased]\n"
    changelog.call(body).problems.first.should.match(/\[Unreleased\] must be the first section/)
  end

  it "blocks a release with no section of its own" do
    changelog.call(good).release_problems("9.9.9").first.should.match(/no section for 9\.9\.9/)
  end

  it "blocks a release that is not the newest section" do
    changelog.call(good).release_problems("4.0.0").first.should.match(/lists 4\.1\.0 above 4\.0\.0/)
  end

  it "reports format problems ahead of release problems" do
    changelog.call("## nonsense\n").release_problems("4.1.0").first.should.match(/malformed version heading/)
  end

  it "loads the repo's own CHANGELOG.md" do
    Gem::Deprecate.skip_during { Brute::Changelog.load.missing?.should.be.false }
  end
end
