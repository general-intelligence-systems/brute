# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module PrimeAgent
  # File-backed continual harness store — the self-learning state ledger.
  #
  # A Ruby port of prime-agent's harness store (prime-agent-runtime
  # src/rlm/harness.py on the kernel side, packages/coding-agent/src/core/
  # refinement/refinement.ts on the host side). One store per (dir, scope);
  # state lives in `<dir>/harness_state.json`:
  #
  #   {
  #     "schema": 1,
  #     "entries": {
  #       "prompt":   { "<id>" => entry, ... },
  #       "memory":   { ... },
  #       "skill":    { ... },
  #       "subagent": { ... }
  #     },
  #     "refinements": [ { "id", "trigger", "changes", "evidence", "outcome", "created_at" } ]
  #   }
  #
  # Entry:
  #   { "id", "kind", "title", "content", "path", "scope",
  #     "reference" => {}, "arguments" => {}, "metadata" => {},
  #     "source" => "agent"|"refine", "created_at", "updated_at", "version" }
  #
  # The same file is shared between the host process and the IRuby kernel:
  # every public method re-syncs from disk when the file's mtime changed, and
  # writes are atomic (temp file + rename). That is prime-agent's dual-writer
  # design — host-side refine writes and kernel-side `harness.*` writes never
  # clobber each other.
  #
  # This file is loaded both by the host and by the kernel bootstrap (stage 3)
  # — keep it free of gem requires (stdlib only) and of `bundler/setup`.
  class HarnessStore
    SCHEMA = 1
    KINDS = %w[prompt memory skill subagent].freeze
    SCOPES = %w[local global].freeze
    ENTRY_KEYS = %w[
      id kind title content path scope reference arguments
      metadata source created_at updated_at version
    ].freeze

    # Adapted from prime-agent's Python overview call contract for the IRuby
    # kernel: no `await`, no rlm subagent spawning (not wired in this port).
    CALL_CONTRACT = <<~TXT.tr("\n", " ").squeeze(" ").freeze
      Ruby REPL skills are invoked by requiring their `import` feature (skill
      lib directories under .brute/skills/*/lib are on the kernel load path) or
      loading their file, then calling the documented callable, e.g.
      `require "json_repair"; JsonRepair.call(...)`. Continual harness skill
      entries are Ruby REPL skills and must include a Ruby `reference` object
      (`{"type" => "ruby", "import" => ..., "callable" => ...}` or a
      `call_pattern`) plus an `arguments` contract. Continual harness subagent
      specs are reusable delegation specs for KernelAgents: invoke one by
      turning it into a concise task prompt and spawning
      `KernelAgent.spawn("<task>")`; admission returns a handle immediately,
      never the child's answer — results arrive via `KernelAgent.finished` on
      a later turn or via files. Do not invent wrappers such as
      `call_skill(...)` or `run_subagent(...)`.
    TXT

    class Error < StandardError; end

    attr_reader :dir, :scope

    def initialize(dir, scope: "local")
      raise Error, "unknown harness scope #{scope.inspect}" unless SCOPES.include?(scope)

      @dir = dir
      @scope = scope
      @state = empty_state
      @fingerprint = nil
    end

    def file_path
      File.join(@dir, "harness_state.json")
    end

    def self.empty_entries
      KINDS.to_h { |kind| [kind, {}] }
    end

    # ------------------------------------------------------------------
    # CRUD — every method syncs from disk first, saves after mutating.
    # ------------------------------------------------------------------

    def create(kind, title, content, id: nil, path: "general", reference: nil, arguments: nil, metadata: nil, source: "agent")
      check_kind(kind)
      validate_skill_reference!(reference, action: "create") if kind == "skill"
      sync_from_disk
      entry_id = id ? self.class.strip_scope_prefix(id).first : nil
      entry_id ||= self.class.slug(title, kind)
      records = @state["entries"][kind]
      raise Error, "#{kind} entry #{entry_id.inspect} already exists" if records.key?(entry_id)

      now = self.class.now
      entry = {
        "id" => entry_id,
        "kind" => kind,
        "title" => title,
        "content" => content,
        "path" => path || "general",
        "scope" => @scope,
        "reference" => reference || {},
        "arguments" => arguments || {},
        "metadata" => metadata || {},
        "source" => source,
        "created_at" => now,
        "updated_at" => now,
        "version" => 1,
      }
      records[entry_id] = entry
      save
      entry
    end

    # Title and content are always replaced; path/reference/arguments/metadata
    # only when non-nil (pass an explicit {} to clear). Bumps version.
    def update(kind, id, title, content, path: nil, reference: nil, arguments: nil, metadata: nil, source: "agent")
      check_kind(kind)
      validate_skill_reference!(reference, action: "update") if kind == "skill" && reference
      sync_from_disk
      entry_id = self.class.strip_scope_prefix(id).first
      before = @state["entries"][kind][entry_id]
      raise Error, "#{kind} entry #{entry_id.inspect} not found" unless before

      entry = before.merge(
        "title" => title,
        "content" => content,
        "path" => path || before["path"],
        "reference" => reference || before["reference"],
        "arguments" => arguments || before["arguments"],
        "metadata" => metadata || before["metadata"],
        "source" => source,
        "updated_at" => self.class.now,
        "version" => before["version"].to_i + 1,
      )
      @state["entries"][kind][entry_id] = entry
      save
      entry
    end

    def upsert(kind, title, content, **kwargs)
      sync_from_disk
      entry_id = kwargs[:id] ? self.class.strip_scope_prefix(kwargs[:id]).first : self.class.slug(title, kind)
      if @state["entries"][kind].key?(entry_id)
        update(kind, entry_id, title, content, **kwargs.reject { |key, _| key == :id })
      else
        create(kind, title, content, **kwargs)
      end
    end

    def get(kind, id)
      check_kind(kind)
      sync_from_disk
      @state["entries"][kind][self.class.strip_scope_prefix(id).first]
    end

    def delete(kind, id)
      check_kind(kind)
      sync_from_disk
      removed = @state["entries"][kind].delete(self.class.strip_scope_prefix(id).first)
      save if removed
      !removed.nil?
    end

    def list(kind = nil)
      sync_from_disk
      kinds = kind ? [check_kind(kind)] : KINDS
      kinds.flat_map { |k| @state["entries"][k].values }
           .sort_by { |entry| [entry["kind"], entry["path"], entry["title"], entry["id"]] }
    end

    def refinements
      sync_from_disk
      @state["refinements"]
    end

    def record_refinement(trigger, changes, evidence: "", outcome: "", id: nil)
      sync_from_disk
      changes = [changes] if changes.is_a?(String)
      event = {
        "id" => id || format("refine_%04d", @state["refinements"].length + 1),
        "trigger" => trigger,
        "changes" => changes,
        "evidence" => evidence,
        "outcome" => outcome,
        "created_at" => self.class.now,
      }
      @state["refinements"] << event
      save
      event
    end

    # A plain-dump view for inspection (not rollback).
    def snapshot
      sync_from_disk
      {
        "file_path" => file_path,
        "scope" => @scope,
        "entries" => deep_copy(@state["entries"]),
        "refinements" => deep_copy(@state["refinements"]),
      }
    end

    # Raw state hash (deep-duped) — the planning/apply currency.
    def state
      sync_from_disk
      deep_copy(@state)
    end

    # Direct entry write used by the refinement apply path (stage 3), which
    # builds the full entry itself including source/version bookkeeping.
    def write_entry(entry)
      check_kind(entry["kind"])
      sync_from_disk
      @state["entries"][entry["kind"]][entry["id"]] = entry.slice(*ENTRY_KEYS)
      save
      entry
    end

    # ------------------------------------------------------------------
    # Overview — the model-facing summary (port of harness.py#overview).
    # ------------------------------------------------------------------

    def overview(max_entries_per_kind: 20, max_content_length: 120)
      sync_from_disk
      lines = [
        "Harness state (#{@scope}): #{file_path}",
        "Call contract: #{CALL_CONTRACT}",
      ]
      KINDS.each do |kind|
        entries = list(kind)
        lines << "#{kind}: #{entries.length}"
        entries.first(max_entries_per_kind).each do |entry|
          lines << "  - #{self.class.summarize_entry(entry, max_content_length)}"
        end
        overflow = entries.length - max_entries_per_kind
        lines << "  - +#{overflow} more" if overflow.positive?
      end
      lines << "refinements: #{@state["refinements"].length}"
      @state["refinements"].last(5).each do |event|
        changes = event["changes"].empty? ? "no applied edits" : event["changes"].join(", ")
        lines << "  - [#{event["id"]}] #{self.class.compact_text(event["trigger"], max_content_length)}: #{changes}"
      end
      lines.join("\n")
    end

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def self.now
      Time.now.utc.iso8601
    end

    def self.slug(title, kind)
      slug = title.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/_+/, "_").gsub(/\A_|_\z/, "")
      slug = slug[0, 80]
      slug.empty? ? kind : slug
    end

    # "local:foo" / "global:foo" display prefixes → ["foo", "local"|"global"].
    def self.strip_scope_prefix(id)
      match = /\A(local|global):(.+)\z/.match(id.to_s)
      match ? [match[2], match[1]] : [id.to_s, nil]
    end

    def self.compact_text(text, max_length)
      normalized = text.to_s.gsub(/\s+/, " ").strip
      return normalized if normalized.length <= max_length

      "#{normalized[0, [max_length - 3, 0].max]}..."
    end

    def self.summarize_entry(entry, max_content_length)
      reference_text = ""
      arguments_text = ""
      if entry["kind"] == "skill"
        unless entry["reference"].to_h.empty?
          reference_text = " ref=#{compact_text(JSON.generate(entry["reference"]), max_content_length)}"
        end
        unless entry["arguments"].to_h.empty?
          arguments_text = " args=#{compact_text(JSON.generate(entry["arguments"]), max_content_length)}"
        end
      end
      "[#{entry["scope"] || "global"}:#{entry["id"]}] #{entry["title"]} " \
        "(#{entry["path"]}, v#{entry["version"]})#{reference_text}#{arguments_text}: " \
        "#{compact_text(entry["content"], max_content_length)}"
    end

    # Skill entries are Ruby REPL skills: the reference must name a
    # require-able import and a callable / call pattern. (prime-agent
    # validates type "python"; this port's kernel is Ruby.)
    def validate_skill_reference!(reference, action:)
      raise Error, "#{action} skill requires ruby reference" unless reference.is_a?(Hash)

      reference = reference.transform_keys(&:to_s)
      unless reference["type"] == "ruby"
        raise Error, "#{action} skill reference.type must be ruby"
      end

      has_import = %w[import require].any? { |key| reference[key].is_a?(String) && !reference[key].empty? }
      has_callable = %w[callable call_pattern].any? { |key| reference[key].is_a?(String) && !reference[key].empty? }
      raise Error, "#{action} skill requires a ruby import" unless has_import
      raise Error, "#{action} skill requires callable or call_pattern" unless has_callable

      true
    end

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    # Reload when the file changed on disk (host refine writes vs kernel
    # `harness.*` writes share the file).
    def sync_from_disk
      fingerprint = file_fingerprint
      load_from_disk if fingerprint != @fingerprint
    end

    def save
      FileUtils.mkdir_p(@dir)
      tmp = "#{file_path}.#{Process.pid}.#{SecureRandom.uuid}.tmp"
      mode = File.exist?(file_path) ? File.stat(file_path).mode & 0o777 : 0o600
      File.write(tmp, "#{JSON.pretty_generate(@state)}\n")
      File.chmod(mode, tmp)
      File.rename(tmp, file_path)
      @fingerprint = file_fingerprint
      true
    end

    private

    def empty_state
      { "schema" => SCHEMA, "entries" => self.class.empty_entries, "refinements" => [] }
    end

    def check_kind(kind)
      raise Error, "unknown harness kind #{kind.inspect}; expected one of #{KINDS.inspect}" unless KINDS.include?(kind)

      kind
    end

    def deep_copy(object)
      Marshal.load(Marshal.dump(object))
    end

    def file_fingerprint
      stat = File.stat(file_path)
      [stat.mtime.to_i, stat.mtime.nsec, stat.size]
    rescue Errno::ENOENT
      nil
    end

    def load_from_disk
      @fingerprint = file_fingerprint
      @state = empty_state
      return unless @fingerprint

      parsed = JSON.parse(File.read(file_path))
      return unless parsed.is_a?(Hash)

      load_entries(parsed["entries"])
      load_refinements(parsed["refinements"])
    rescue JSON::ParserError, Errno::ENOENT
      @state = empty_state
    end

    def load_entries(raw)
      return unless raw.is_a?(Hash)

      KINDS.each do |kind|
        records = raw[kind]
        next unless records.is_a?(Hash)

        records.each do |id, entry|
          normalized = normalize_entry(kind, id, entry)
          @state["entries"][kind][normalized["id"]] = normalized if normalized
        end
      end
    end

    # Defensive load, mirroring harness.py: unknown keys dropped, entries
    # with bad title/content skipped, bad fields defaulted.
    def normalize_entry(kind, id, entry)
      return nil unless entry.is_a?(Hash)
      return nil unless entry["title"].is_a?(String) && entry["content"].is_a?(String)

      {
        "id" => entry["id"].is_a?(String) && !entry["id"].empty? ? entry["id"] : id.to_s,
        "kind" => kind,
        "title" => entry["title"],
        "content" => entry["content"],
        "path" => entry["path"].is_a?(String) && !entry["path"].empty? ? entry["path"] : "general",
        "scope" => SCOPES.include?(entry["scope"]) ? entry["scope"] : @scope,
        "reference" => entry["reference"].is_a?(Hash) ? entry["reference"] : {},
        "arguments" => entry["arguments"].is_a?(Hash) ? entry["arguments"] : {},
        "metadata" => entry["metadata"].is_a?(Hash) ? entry["metadata"] : {},
        "source" => entry["source"].is_a?(String) ? entry["source"] : "agent",
        "created_at" => entry["created_at"].is_a?(String) ? entry["created_at"] : self.class.now,
        "updated_at" => entry["updated_at"].is_a?(String) ? entry["updated_at"] : self.class.now,
        "version" => entry["version"].to_i.positive? ? entry["version"].to_i : 1,
      }
    end

    def load_refinements(raw)
      return unless raw.is_a?(Array)

      raw.each do |event|
        next unless event.is_a?(Hash)
        next unless event["id"].is_a?(String) && event["trigger"].is_a?(String)
        next unless event["changes"].is_a?(Array)

        @state["refinements"] << {
          "id" => event["id"],
          "trigger" => event["trigger"],
          "changes" => event["changes"],
          "evidence" => event["evidence"].is_a?(String) ? event["evidence"] : "",
          "outcome" => event["outcome"].is_a?(String) ? event["outcome"] : "",
          "created_at" => event["created_at"].is_a?(String) ? event["created_at"] : self.class.now,
        }
      end
    end
  end

  # The model-facing harness handle — prime-agent's `rlm.harness` proxy.
  # Routes CRUD calls to the local store by default, to the global store with
  # `global_: true` (or a `global:` id prefix). Used from the IRuby kernel
  # (as `harness`, stage 3) and by the host middleware alike.
  class Harness
    TYPED_KINDS = %w[memory skill subagent].freeze

    attr_reader :local_store, :global_store

    def initialize(local_store:, global_store:)
      @local_store = local_store
      @global_store = global_store
    end

    TYPED_KINDS.each do |kind|
      define_method("create_#{kind}") do |title, content, global_: false, **kwargs|
        store_for(id: nil, global_: global_).create(kind, title, content, **kwargs)
      end

      define_method("update_#{kind}") do |id, title, content, global_: false, **kwargs|
        store_for(id: id, global_: global_)
          .update(kind, HarnessStore.strip_scope_prefix(id).first, title, content, **kwargs)
      end

      define_method("delete_#{kind}") do |id, global_: false|
        store_for(id: id, global_: global_).delete(kind, HarnessStore.strip_scope_prefix(id).first)
      end
    end

    def create_prompt_note(title, content, global_: false, path: "policy", **kwargs)
      store_for(id: nil, global_: global_).create("prompt", title, content, path: path, **kwargs)
    end

    def update_prompt_note(id, title, content, global_: false, **kwargs)
      store_for(id: id, global_: global_)
        .update("prompt", HarnessStore.strip_scope_prefix(id).first, title, content, **kwargs)
    end

    def delete_prompt_note(id, global_: false)
      store_for(id: id, global_: global_).delete("prompt", HarnessStore.strip_scope_prefix(id).first)
    end

    def get(kind, id, global_: false)
      store_for(id: id, global_: global_).get(kind, id)
    end

    def list(kind = nil, global_: false)
      store_for(id: nil, global_: global_).list(kind)
    end

    def record_refinement(trigger, changes, evidence: "", outcome: "", global_: false)
      store_for(id: nil, global_: global_)
        .record_refinement(trigger, changes, evidence: evidence, outcome: outcome)
    end

    def overview(global_: false, **options)
      store_for(id: nil, global_: global_).overview(**options)
    end

    def get_harness_state(global_: false)
      store_for(id: nil, global_: global_)
    end

    def snapshot(global_: false)
      store_for(id: nil, global_: global_).snapshot
    end

    # The prompt/planning view: local entries overlay global ones; on an id
    # collision the local entry is keyed "local:<id>". Refinement events from
    # both stores are concatenated. (Port of mergeHarnessStates.)
    def merged_state
      global_state = @global_store.state
      local_state = @local_store.state
      entries = HarnessStore.empty_entries
      HarnessStore::KINDS.each do |kind|
        global_state["entries"][kind].each do |id, entry|
          entries[kind][id] = entry.merge("scope" => "global")
        end
        local_state["entries"][kind].each do |id, entry|
          key = entries[kind].key?(id) ? "local:#{id}" : id
          entries[kind][key] = entry.merge("scope" => "local")
        end
      end
      {
        "schema" => HarnessStore::SCHEMA,
        "entries" => entries,
        "refinements" => global_state["refinements"] + local_state["refinements"],
      }
    end

    private

    def store_for(id:, global_:)
      return @global_store if global_

      _bare, forced = id ? HarnessStore.strip_scope_prefix(id) : [nil, nil]
      forced == "global" ? @global_store : @local_store
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/harness_store" do
  def with_store(scope: "local", &block)
    Dir.mktmpdir { |dir| block.call(PrimeAgent::HarnessStore.new(dir, scope: scope), dir) }
  end

  it "creates and reads back entries across instances (file-backed)" do
    Dir.mktmpdir do |dir|
      PrimeAgent::HarnessStore.new(dir, scope: "local")
                              .create("memory", "Prefers ripgrep", "Always search with rg, not grep")

      entry = PrimeAgent::HarnessStore.new(dir, scope: "local").get("memory", "prefers_ripgrep")
      entry["title"].should == "Prefers ripgrep"
      entry["version"].should == 1
      entry["scope"].should == "local"
      entry["source"].should == "agent"
      entry["path"].should == "general"
    end
  end

  it "writes the exact schema shape" do
    with_store do |store, dir|
      store.create("memory", "Fact", "Content")
      parsed = JSON.parse(File.read(File.join(dir, "harness_state.json")))
      parsed["schema"].should == 1
      parsed["entries"].keys.sort.should == %w[memory prompt skill subagent]
      parsed["refinements"].should == []
      entry = parsed["entries"]["memory"]["fact"]
      PrimeAgent::HarnessStore::ENTRY_KEYS.each { |key| entry.key?(key).should.be.true }
    end
  end

  it "rejects duplicate create and missing update" do
    with_store do |store|
      store.create("memory", "Fact", "v1")
      lambda { store.create("memory", "Fact", "v2") }.should.raise(PrimeAgent::HarnessStore::Error)
      lambda { store.update("memory", "nope", "t", "c") }.should.raise(PrimeAgent::HarnessStore::Error)
    end
  end

  it "update replaces title/content, keeps path, bumps version" do
    with_store do |store|
      store.create("memory", "Fact", "v1", path: "project")
      updated = store.update("memory", "fact", "Fact v2", "v2")
      updated["path"].should == "project"
      updated["version"].should == 2
      store.get("memory", "fact")["title"].should == "Fact v2"
    end
  end

  it "slugs ids and strips scope prefixes" do
    PrimeAgent::HarnessStore.slug("Hello, World! 2026", "memory").should == "hello_world_2026"
    PrimeAgent::HarnessStore.slug("!!!", "memory").should == "memory"
    PrimeAgent::HarnessStore.strip_scope_prefix("global:foo").should == ["foo", "global"]
    PrimeAgent::HarnessStore.strip_scope_prefix("foo").should == ["foo", nil]
  end

  it "validates skill references (ruby type, import, callable)" do
    with_store do |store|
      lambda { store.create("skill", "S", "c") }.should.raise(PrimeAgent::HarnessStore::Error)
      lambda {
        store.create("skill", "S", "c", reference: { "type" => "python", "import" => "x", "callable" => "y" })
      }.should.raise(PrimeAgent::HarnessStore::Error)
      lambda {
        store.create("skill", "S", "c", reference: { "type" => "ruby", "callable" => "y" })
      }.should.raise(PrimeAgent::HarnessStore::Error)
      entry = store.create("skill", "S", "c",
                           reference: { "type" => "ruby", "import" => "json_repair",
                                        "call_pattern" => "JsonRepair.call(x)" },
                           arguments: { "x" => { "type" => "string", "required" => true } })
      entry["reference"]["type"].should == "ruby"
    end
  end

  it "records refinements with sequential ids" do
    with_store do |store|
      e1 = store.record_refinement("manual", ["create memory:a"])
      e2 = store.record_refinement("manual", "create memory:b", outcome: "learned")
      e1["id"].should == "refine_0001"
      e2["id"].should == "refine_0002"
      e2["changes"].should == ["create memory:b"]
      store.refinements.size.should == 2
    end
  end

  it "survives corrupt state files (defensive load)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "harness_state.json"), "{ not json")
      store = PrimeAgent::HarnessStore.new(dir, scope: "local")
      store.list.should == []
      File.write(File.join(dir, "harness_state.json"),
                 JSON.generate({ "entries" => { "memory" => {
                   "bad" => { "title" => 1 },
                   "ok" => { "id" => "ok", "title" => "T", "content" => "C" },
                 } } }))
      store.list.map { |entry| entry["id"] }.should == ["ok"]
    end
  end

  it "syncs from disk when another writer changes the file" do
    Dir.mktmpdir do |dir|
      a = PrimeAgent::HarnessStore.new(dir, scope: "local")
      b = PrimeAgent::HarnessStore.new(dir, scope: "local")
      a.create("memory", "From A", "x")
      b.get("memory", "from_a")["title"].should == "From A"
      b.create("memory", "From B", "y")
      a.list.size.should == 2
    end
  end

  it "routes proxy calls by global_ flag and global: prefix" do
    Dir.mktmpdir do |local_dir|
      Dir.mktmpdir do |global_dir|
        harness = PrimeAgent::Harness.new(
          local_store: PrimeAgent::HarnessStore.new(local_dir, scope: "local"),
          global_store: PrimeAgent::HarnessStore.new(global_dir, scope: "global"),
        )
        harness.create_memory("Local fact", "l")
        harness.create_memory("Global fact", "g", global_: true)
        harness.local_store.list.size.should == 1
        harness.global_store.list.size.should == 1
        harness.delete_memory("global:global_fact").should == true
        harness.global_store.list.size.should == 0
        harness.create_prompt_note("Tone", "be terse")
        harness.local_store.get("prompt", "tone")["path"].should == "policy"
      end
    end
  end

  it "merged_state overlays local on global with local: collision keys" do
    Dir.mktmpdir do |local_dir|
      Dir.mktmpdir do |global_dir|
        harness = PrimeAgent::Harness.new(
          local_store: PrimeAgent::HarnessStore.new(local_dir, scope: "local"),
          global_store: PrimeAgent::HarnessStore.new(global_dir, scope: "global"),
        )
        harness.create_memory("Same", "global version", global_: true)
        harness.create_memory("Same", "local version")
        merged = harness.merged_state["entries"]["memory"]
        merged["same"]["scope"].should == "global"
        merged["local:same"]["scope"].should == "local"
      end
    end
  end

  it "overview renders scope prefixes, versions and refinement events" do
    with_store do |store|
      store.create("memory", "Fact", "some content")
      store.record_refinement("manual", ["create memory:fact"])
      out = store.overview
      out.should.include "Harness state (local):"
      out.should.include "memory: 1"
      out.should.include "[local:fact] Fact (general, v1): some content"
      out.should.include "refinements: 1"
      out.should.include "create memory:fact"
    end
  end
end
