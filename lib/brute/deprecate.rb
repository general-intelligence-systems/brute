# frozen_string_literal: true

require "gem_kit"

module Brute
  # Deprecated. This is [`GemKit::Deprecate`](https://rubygems.org/gems/gem_kit)
  # now — the same code, extracted so that other gems could use it, and so that
  # `gem kit deprecations` could read one registry rather than two.
  #
  #   extend Brute::Deprecate     ->  extend GemKit::Deprecate
  #   brute_deprecate             ->  deprecate
  #   brute_deprecate_constant    ->  superseded_by
  #
  # Extending this module still works and still registers: it warns, then
  # extends GemKit::Deprecate for you and aliases the old method names onto the
  # new ones. It will stop working in 5.0.
  module Deprecate
    REPLACEMENT = "GemKit::Deprecate"
    REMOVED_IN  = "5.0"

    # The names Brute used before the extraction. `deprecate` collides with
    # Gem::Deprecate's own, which is why Brute's carried a prefix; GemKit's
    # namespace does that job instead.
    ALIASES = { brute_deprecate: :deprecate, brute_deprecate_constant: :superseded_by }.freeze

    def self.extended(base)
      origin = Gem.location_of_caller.join(":")
      GemKit::Deprecate.warn(
        GemKit::Deprecate.message("Brute::Deprecate", REPLACEMENT, REMOVED_IN, origin),
      )

      base.extend(GemKit::Deprecate)
      ALIASES.each { |old, new| base.singleton_class.alias_method(old, new) }
    end

    # The registry moved with the DSL. Delegated rather than mirrored: two
    # registries meant two answers to "what is still outstanding".
    class << self
      def registry            = GemKit::Deprecate.registry
      def pending(version)    = GemKit::Deprecate.pending(version)
      def upcoming(version)   = GemKit::Deprecate.upcoming(version)
      def register(...)       = GemKit::Deprecate.register(...)
      def warn(message)       = GemKit::Deprecate.warn(message)
    end
  end
end

# The module itself is deprecated, and a module cannot announce that the way a
# class can — there is no `new` to wrap. Registering it by hand is what puts it
# in `gem kit deprecations` alongside everything else.
GemKit::Deprecate.register(
  name:        "Brute::Deprecate",
  replacement: Brute::Deprecate::REPLACEMENT,
  removed_in:  Brute::Deprecate::REMOVED_IN,
  declared_at: "#{__FILE__}:#{__LINE__ - 5}",
)

__END__

describe "brute/deprecate" do
  captured = []
  # Capture what the shim emits, and keep the shared registry clean.
  isolated = lambda do |&block|
    saved    = GemKit::Deprecate.registry.dup
    original = GemKit::Deprecate.method(:warn)
    captured.clear
    GemKit::Deprecate.define_singleton_method(:warn) { |message| captured << message }
    begin
      block.call
    ensure
      GemKit::Deprecate.define_singleton_method(:warn, original)
      GemKit::Deprecate.registry.replace(saved)
    end
  end

  it "warns when extended, naming GemKit::Deprecate" do
    isolated.call do
      Class.new { extend Brute::Deprecate }

      captured.size.should == 1
      captured.first.should.match(/Brute::Deprecate is deprecated/)
      captured.first.should.match(/use GemKit::Deprecate instead/)
      captured.first.should.match(/removed in 5\.0/)
    end
  end

  it "still declares a method deprecation under the old name" do
    isolated.call do
      klass = Class.new do
        extend Brute::Deprecate
        def new_name = :result
        def old_name = new_name
        brute_deprecate :old_name, "Thing#new_name", "9.0"
      end

      klass.new.old_name.should == :result
      GemKit::Deprecate.registry.last.replacement.should == "Thing#new_name"
    end
  end

  it "still declares a constant deprecation under the old name" do
    isolated.call do
      modern = Class.new { def initialize(x); @x = x; end; attr_reader :x }
      legacy = Class.new(modern) do
        extend Brute::Deprecate
        def self.name = "Old::Name"
        brute_deprecate_constant "New::Name", "9.0"
      end

      legacy.new(42).x.should == 42
      GemKit::Deprecate.registry.last.name.should == "Old::Name"
    end
  end

  it "delegates the registry rather than keeping one of its own" do
    isolated.call do
      Brute::Deprecate.registry.should.equal?(GemKit::Deprecate.registry)

      GemKit::Deprecate.register(name: "A", replacement: "A2", removed_in: "5.0")
      Brute::Deprecate.pending("5.0.0").map(&:name).should.include?("A")
      Brute::Deprecate.upcoming("4.0.0").map(&:name).should.include?("A")
    end
  end

  it "registers itself, so `gem kit deprecations` lists it" do
    entry = GemKit::Deprecate.registry.find { |e| e.name == "Brute::Deprecate" }

    entry.should.not.be.nil
    entry.replacement.should == "GemKit::Deprecate"
    entry.removed_in.should == Gem::Version.new("5.0")
  end
end
