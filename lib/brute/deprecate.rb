# frozen_string_literal: true

require "rubygems/deprecate"

module Brute
  # Brute's deprecation policy, built on Gem::Deprecate.
  #
  # Rubygems' own convention is the one worth copying: a deprecation names its
  # replacement and the *version it will be removed in*, so "deprecated" is a
  # dated promise rather than an open-ended apology. Brute adds one thing on
  # top — a registry. Every declaration records itself, which turns the set of
  # outstanding deprecations into data the tooling can act on:
  #
  #   bin/deprecations             # list everything still outstanding
  #   bin/increment-version major  # refuses to bump past a removal deadline
  #
  # Deprecate a method:
  #
  #   class Session
  #     extend Brute::Deprecate
  #
  #     def old_reset; new_reset; end
  #     brute_deprecate :old_reset, "Session#new_reset", "5.0"
  #   end
  #
  # Deprecate a whole class — a renamed or moved constant. Leave the old name
  # in place as a subclass of the new one, then declare it:
  #
  #   class Completion < Brute::Completion::OpenRouter
  #     extend Brute::Deprecate
  #     brute_deprecate_constant "Brute::Completion::OpenRouter", "5.0"
  #   end
  #
  # Both warn on use, naming the caller. Gem::Deprecate.skip_during { ... }
  # silences them, so a test suite can exercise the old path in quiet.
  module Deprecate
    extend Gem::Deprecate

    # One outstanding deprecation. `removed_in` is the version the old name
    # stops existing in — the deadline both CLI commands read.
    Entry = Struct.new(:name, :replacement, :removed_in, :declared_at, keyword_init: true) do
      def to_s
        "#{name} -> #{replacement == :none ? "(no replacement)" : replacement}"
      end
    end

    class << self
      # Every deprecation declared in the loaded library, in declaration order.
      def registry
        @registry ||= []
      end

      # Record a deprecation. Returns the Entry.
      def register(name:, replacement:, removed_in:, declared_at: nil)
        entry = Entry.new(
          name:        name.to_s,
          replacement: replacement,
          removed_in:  Gem::Version.new(removed_in.to_s),
          declared_at: declared_at || caller_locations(1, 1)&.first&.then { |l| "#{l.path}:#{l.lineno}" },
        )
        registry << entry
        entry
      end

      # The deprecations that come due at `version` — everything whose removal
      # deadline has arrived or passed. This is the gate: releasing `version`
      # with any of these still present breaks the promise the warning made.
      def pending(version)
        target = Gem::Version.new(version.to_s)
        registry.select { |entry| entry.removed_in <= target }
      end

      # Deprecations still in their grace period at `version`.
      def upcoming(version)
        target = Gem::Version.new(version.to_s)
        registry.reject { |entry| entry.removed_in <= target }
      end

      # The default deadline: the next major version after the current one.
      def next_major_version
        Gem::Version.new(Brute::VERSION.split(".").first).bump.to_s
      end

      # Single funnel for every warning, so Gem::Deprecate.skip_during works
      # across all of them and specs have one place to listen.
      def warn(message)
        Kernel.warn(message) unless Gem::Deprecate.skip
      end

      # Build the Gem::Deprecate-shaped message body. `origin` must be
      # computed at the call site — one frame deeper and it names this file
      # rather than the code that needs changing.
      def message(target, replacement, removed_in, origin)
        [
          "NOTE: #{target} is deprecated",
          replacement == :none ? " with no replacement" : "; use #{replacement} instead",
          ". It will be removed in Brute #{removed_in}",
          "\n#{target} called from #{origin}.",
        ].join
      end
    end

    # Deprecate one method. Mirrors Gem::Deprecate#rubygems_deprecate, but the
    # deadline is explicit rather than "the next major" — a deprecation added
    # late in a cycle usually wants the major after next.
    def brute_deprecate(name, replacement = :none, removed_in = Brute::Deprecate.next_major_version)
      label = singleton_class? ? "#{attached_object}.#{name}" : "#{self}##{name}"
      Brute::Deprecate.register(
        name:        label,
        replacement: replacement,
        removed_in:  removed_in,
        declared_at: caller_locations(1, 1)&.first&.then { |l| "#{l.path}:#{l.lineno}" },
      )

      class_eval do
        old = "_deprecated_#{name}"
        alias_method old, name
        define_method name do |*args, &block|
          target = is_a?(Module) ? "#{self}.#{name}" : "#{self.class}##{name}"
          origin = Gem.location_of_caller.join(":")
          Brute::Deprecate.warn(Brute::Deprecate.message(target, replacement, removed_in, origin))
          send(old, *args, &block)
        end
        ruby2_keywords name if respond_to?(:ruby2_keywords, true)
      end
    end

    # Deprecate a whole constant — the renamed-or-moved case. Call it in the
    # body of the old name (kept as a subclass of the new one); it registers
    # the rename and warns whenever the old name is instantiated.
    def brute_deprecate_constant(replacement, removed_in = Brute::Deprecate.next_major_version)
      Brute::Deprecate.register(
        name:        name || to_s,
        replacement: replacement,
        removed_in:  removed_in,
        declared_at: caller_locations(1, 1)&.first&.then { |l| "#{l.path}:#{l.lineno}" },
      )

      return unless respond_to?(:new)

      define_singleton_method(:new) do |*args, **options, &block|
        origin = Gem.location_of_caller.join(":")
        Brute::Deprecate.warn(Brute::Deprecate.message(name || to_s, replacement, removed_in, origin))
        super(*args, **options, &block)
      end
    end
  end
end

__END__

describe "brute/deprecate" do
  # Capture what Brute::Deprecate.warn emits, and keep the shared registry
  # clean — these specs declare throwaway deprecations.
  captured = []
  around_each = lambda do |&block|
    saved = Brute::Deprecate.registry.dup
    original = Brute::Deprecate.method(:warn)
    captured.clear
    Brute::Deprecate.define_singleton_method(:warn) { |message| captured << message }
    begin
      block.call
    ensure
      Brute::Deprecate.define_singleton_method(:warn, original)
      Brute::Deprecate.registry.replace(saved)
    end
  end

  it "warns on a deprecated method, naming the replacement, version and caller" do
    around_each.call do
      klass = Class.new do
        extend Brute::Deprecate
        def new_name = :result
        def old_name = new_name
        brute_deprecate :old_name, "Thing#new_name", "9.0"
      end

      klass.new.old_name.should == :result   # still works
      captured.size.should == 1
      captured.first.should.match(/is deprecated/)
      captured.first.should.match(/use Thing#new_name instead/)
      captured.first.should.match(/removed in Brute 9\.0/)
      captured.first.should.match(/called from /)
    end
  end

  it "warns on a deprecated constant but keeps it working" do
    around_each.call do
      modern = Class.new { def initialize(x); @x = x; end; attr_reader :x }
      legacy = Class.new(modern) do
        extend Brute::Deprecate
        def self.name = "Old::Name"
        brute_deprecate_constant "New::Name", "9.0"
      end

      legacy.new(42).x.should == 42          # still works
      captured.size.should == 1
      captured.first.should.match(/Old::Name is deprecated; use New::Name instead/)
    end
  end

  it "names the caller, not the deprecation machinery" do
    around_each.call do
      klass = Class.new do
        extend Brute::Deprecate
        def old_name = :result
        brute_deprecate :old_name, "Thing#new_name", "9.0"
      end

      # These specs live in this file's __END__, so "the caller" is a line in
      # deprecate.rb either way — pin the exact line to tell them apart.
      klass.new.old_name; call_line = __LINE__
      captured.first.should.match(/called from .*deprecate\.rb:#{call_line}\./)
    end
  end

  it "labels a class-method deprecation by the class, not its singleton" do
    around_each.call do
      Class.new do
        def self.to_s = "Demo"
        def self.old_thing = :ok
        class << self
          extend Brute::Deprecate
          brute_deprecate :old_thing, "Other.new_thing", "9.0"
        end
      end

      Brute::Deprecate.registry.last.name.should == "Demo.old_thing"
    end
  end

  it "registers each declaration with its deadline and source" do
    around_each.call do
      Class.new do
        extend Brute::Deprecate
        def gone = nil
        brute_deprecate :gone, "Other#kept", "9.0"
      end

      entry = Brute::Deprecate.registry.last
      entry.replacement.should == "Other#kept"
      entry.removed_in.should == Gem::Version.new("9.0")
      entry.declared_at.should.match(/deprecate\.rb:\d+/)
    end
  end

  it "splits the registry into pending (due) and upcoming at a version" do
    around_each.call do
      Brute::Deprecate.registry.clear
      Brute::Deprecate.register(name: "A", replacement: "A2", removed_in: "5.0")
      Brute::Deprecate.register(name: "B", replacement: "B2", removed_in: "6.0")

      Brute::Deprecate.pending("5.0.0").map(&:name).should == ["A"]
      Brute::Deprecate.upcoming("5.0.0").map(&:name).should == ["B"]
      Brute::Deprecate.pending("4.9.0").should.be.empty
      Brute::Deprecate.pending("6.1.0").map(&:name).should == ["A", "B"]
    end
  end

  it "defaults the deadline to the next major version" do
    around_each.call do
      Brute::Deprecate.next_major_version.should == Gem::Version.new(Brute::VERSION.split(".").first).bump.to_s
    end
  end

  it "stays quiet inside Gem::Deprecate.skip_during" do
    saved = Brute::Deprecate.registry.dup
    begin
      klass = Class.new do
        extend Brute::Deprecate
        def quiet = :ok
        brute_deprecate :quiet, "Other#loud", "9.0"
      end

      warned = []
      original = Kernel.method(:warn)
      Kernel.define_singleton_method(:warn) { |*args| warned << args.join }
      begin
        Gem::Deprecate.skip_during { klass.new.quiet.should == :ok }
      ensure
        Kernel.define_singleton_method(:warn, original)
      end

      warned.should.be.empty
    ensure
      Brute::Deprecate.registry.replace(saved)
    end
  end
end
