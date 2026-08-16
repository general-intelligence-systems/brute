# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module PrimeAgent
  # AgentFamily — the agent-to-agent family bus core. The port of prime-agent's
  # packages/coding-agent/src/core/agent-messages.ts: the "nuclear family"
  # roster (parent / siblings / direct children only), message validation and
  # limits, the injected prompt text, receipts, and the rate limiter.
  #
  # Delivery-model adaptation (same one as heartbeats): upstream steers
  # messages into a resident session; here agents are KernelAgent threads plus
  # the root run, so a send appends to the target's mailbox FILE
  # (<bus_dir>/<id>-mailbox.jsonl) and the target's own AgentMessages
  # middleware delivers it at its next turn boundary. Receipts are therefore
  # "queued" for live targets (upstream's busy-case); a send to a terminal or
  # unknown target raises — spawn a new child instead of reviving one.
  #
  # Pure stdlib — loadable without brute or any gem.
  module AgentFamily
    CUSTOM_TYPE = "agent_message"
    SKILL_NAME = "agent-message"
    SOURCE = "agent_message"

    MAX_CHARS = 16_384              # DEFAULT_AGENT_MESSAGE_MAX_CHARS
    MAX_PENDING_PER_SESSION = 20    # DEFAULT_AGENT_MESSAGE_MAX_PENDING_PER_SESSION
    RATE_LIMIT_CAPACITY = 3         # DEFAULT_AGENT_MESSAGE_RATE_LIMIT_CAPACITY
    RATE_LIMIT_REFILL_MS = 1000     # DEFAULT_AGENT_MESSAGE_RATE_LIMIT_REFILL_MS

    FAMILY_REACH_ERROR = "Agent reach is limited to parent, siblings, and children"
    RELATIONSHIPS = %w[parent sibling child].freeze

    module_function

    # ------------------------------------------------------------------
    # Validation (agent-messages.ts:334-365)
    # ------------------------------------------------------------------

    def normalize_message(message, max_chars = MAX_CHARS)
      trimmed = message.to_s.strip
      raise ArgumentError, "Agent session message cannot be empty" if trimmed.empty?
      if trimmed.length > max_chars
        raise ArgumentError,
              "Agent session message is too long: #{trimmed.length} chars exceeds #{max_chars}"
      end

      trimmed
    end

    # Broadcast targets are rejected for direct sends (broadcast lives only
    # in the kernel proxy's fan-out form).
    def assert_direct_target(target)
      normalized = target.to_s.strip
      raise ArgumentError, "Agent message target cannot be empty" if normalized.empty?
      if normalized == "*" || %w[all broadcast].include?(normalized.downcase)
        raise ArgumentError, "Broadcast agent messaging is not supported"
      end

      normalized
    end

    def assert_queue_capacity(pending, max_pending = MAX_PENDING_PER_SESSION)
      return unless pending >= max_pending

      raise ArgumentError,
            "Target session has too many pending messages: #{pending} unfinished, limit is #{max_pending}"
    end

    # ------------------------------------------------------------------
    # Roster (buildAgentFamilyRoster, agent-messages.ts:216-250)
    #
    # Catalog entries and `current` are Hashes with :id, :name, :depth,
    # :status, :parent_id (and optionally :replied_since_task for children).
    # ------------------------------------------------------------------

    def build_roster(current, catalog)
      parent = catalog.find { |entry| entry[:id] == current[:parent_id] }
      siblings = catalog.select do |entry|
        entry[:id] != current[:id] && entry[:depth] == current[:depth] &&
          entry[:parent_id] == current[:parent_id]
      end
      children = catalog.select do |entry|
        entry[:depth] == current[:depth] + 1 && entry[:parent_id] == current[:id]
      end

      row = lambda do |relationship, entry|
        {
          "relationship" => relationship,
          "name" => entry[:name] || entry[:id],
          "id" => entry[:id],
          "depth" => entry[:depth],
          "status" => entry[:status],
        }.tap do |r|
          r["replied_since_task"] = entry[:replied_since_task] if relationship == "child" && !entry[:replied_since_task].nil?
        end
      end

      {
        "current" => {
          "name" => current[:name] || current[:id],
          "id" => current[:id],
          "depth" => current[:depth],
        },
        "entries" => [
          *(parent ? [row.call("parent", parent)] : []),
          *siblings.sort_by { |entry| entry[:name] || entry[:id] }.map { |entry| row.call("sibling", entry) },
          *children.sort_by { |entry| entry[:name] || entry[:id] }.map { |entry| row.call("child", entry) },
        ],
      }
    end

    # ------------------------------------------------------------------
    # The injected prompt (createAgentSessionMessagePrompt,
    # agent-messages.ts:388-405) — delivered as a user message at the
    # target's next turn boundary (upstream flattens custom → user too).
    # ------------------------------------------------------------------

    def build_prompt(from:, from_relationship:, target:, id:, message:)
      lines = []
      if from_relationship
        suffix = from_relationship == "parent" ? "" : ":#{sanitize_metadata(from[:name] || from[:id])}"
        lines << "[from #{from_relationship}#{suffix}]"
      end
      lines << "Agent-to-agent message received."
      lines << "Source: #{SOURCE}"
      lines << "From: #{format_participant(from, unknown: "unknown sender")}" if from
      lines << "To: #{format_participant(target)}"
      lines << "Message id: #{id}"
      lines << ""
      lines << message
      lines.join("\n")
    end

    # Our endpoints are KernelAgent handles (or the root run): one id + one
    # name. (Upstream formats active/session/client ids; the port has a
    # single in-kernel identity.)
    def format_participant(endpoint, unknown: nil)
      name = sanitize_metadata(endpoint[:name].to_s)
      id = sanitize_metadata(endpoint[:id].to_s)
      return unknown || "unknown" if name.empty? && id.empty?
      return id if name.empty?

      "#{name} (#{id})"
    end

    def sanitize_metadata(value)
      value.gsub(/[\s,\[\]]+/, " ").strip
    end

    def new_message_id
      "agentmsg_#{SecureRandom.uuid}"
    end

    # parseAgentSessionMessagePromptId / isAgentSessionMessagePrompt
    # (agent-messages.ts:367-386) — recognize the prompt shape.
    def parse_prompt_id(text)
      lines = text.split("\n")
      offset = lines[0]&.start_with?("[from ") ? 1 : 0
      return nil unless lines[offset] == "Agent-to-agent message received." &&
                        lines[offset + 1] == "Source: #{SOURCE}"

      to_index = lines[offset + 2]&.start_with?("From: ") ? offset + 3 : offset + 2
      return nil unless lines[to_index]&.start_with?("To: ")

      match = /^Message id: (agentmsg_[^\n]+)$/.match(lines[to_index + 1].to_s)
      match && match[1]
    end

    def message_prompt?(text)
      !parse_prompt_id(text).nil?
    end

    # createAgentSessionMessageReceipt (agent-messages.ts:441-460).
    def build_receipt(id:, from:, target:, message:, status:, at: Time.now.utc.iso8601)
      {
        "id" => id,
        "source" => SOURCE,
        "target" => target,
        "from" => from,
        "message" => message,
        "deliveryStatus" => status,
        # deliveryMode is always steer upstream; in this port every delivery
        # is a turn-boundary drain (follow_up semantics) — see the module comment.
        "deliveryMode" => "steer",
      }.merge(status == "delivered" ? { "deliveredAt" => at } : { "queuedAt" => at })
    end

    # ------------------------------------------------------------------
    # Mailbox files (the port's delivery channel)
    # ------------------------------------------------------------------

    def mailbox_path(bus_dir, agent_id)
      File.join(bus_dir, "#{agent_id}-mailbox.jsonl")
    end

    def transcript_path(bus_dir, agent_id)
      File.join(bus_dir, "#{agent_id}-transcript.json")
    end

    # Append one message to the target's mailbox (flock'd JSONL line).
    # Returns the pending count after the append.
    def deliver(bus_dir, target_id, payload)
      FileUtils.mkdir_p(bus_dir)
      path = mailbox_path(bus_dir, target_id)
      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write("#{JSON.generate(payload)}\n")
        file.flush
      end
      pending_count(bus_dir, target_id)
    end

    def pending_count(bus_dir, agent_id)
      path = mailbox_path(bus_dir, agent_id)
      return 0 unless File.exist?(path)

      File.foreach(path).count
    end

    # Read and clear a mailbox (rename-under-lock so concurrent appends are
    # never lost: a send that lands during the drain writes a fresh file).
    def drain_mailbox(bus_dir, agent_id)
      path = mailbox_path(bus_dir, agent_id)
      return [] unless File.exist?(path)

      drained = "#{path}.#{Process.pid}.draining"
      File.rename(path, drained)
      messages = File.foreach(drained).filter_map do |line|
        begin
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
      end
      File.delete(drained)
      messages
    end

    # ------------------------------------------------------------------
    # Rate limiter (AgentSessionMessageRateLimiter, agent-messages.ts:468-523)
    # Token bucket per sender→target key; failures are refunded by the caller.
    # ------------------------------------------------------------------

    class RateLimiter
      def initialize(capacity: RATE_LIMIT_CAPACITY, refill_ms: RATE_LIMIT_REFILL_MS,
                     now: -> { (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).floor })
        @capacity = capacity
        @refill_ms = refill_ms
        @now = now
        @buckets = {}
      end

      def try_consume(key)
        now = @now.call
        bucket = @buckets[key] ||= { tokens: @capacity, updated_at: now }
        elapsed = [0, now - bucket[:updated_at]].max
        refilled = elapsed / @refill_ms
        if refilled.positive?
          bucket[:tokens] = [@capacity, bucket[:tokens] + refilled].min
          bucket[:updated_at] += refilled * @refill_ms
        end
        if bucket[:tokens] <= 0
          return { ok: false, retry_after_ms: [1, bucket[:updated_at] + @refill_ms - now].max }
        end

        bucket[:tokens] -= 1
        { ok: true }
      end

      def refund(key)
        bucket = @buckets[key]
        return unless bucket

        bucket[:tokens] = [@capacity, bucket[:tokens] + 1].min
      end

      def clear(key = nil)
        key ? @buckets.delete(key) : @buckets.clear
      end
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/agent_family" do
  F = PrimeAgent::AgentFamily

  it "validates messages with upstream's errors" do
    F.normalize_message("  hi  ").should == "hi"
    lambda { F.normalize_message("   ") }.should.raise(ArgumentError)
    lambda { F.normalize_message("x" * 16_385) }.should.raise(ArgumentError)
    lambda { F.assert_direct_target("all") }.should.raise(ArgumentError)
    lambda { F.assert_direct_target("*") }.should.raise(ArgumentError)
    F.assert_direct_target(" api-reviewer ").should == "api-reviewer"
  end

  it "builds the nuclear-family roster (parent, sorted siblings and children)" do
    catalog = [
      { id: "root", name: "root", depth: 0, status: "running", parent_id: nil },
      { id: "b", name: "beta", depth: 1, status: "running", parent_id: "root" },
      { id: "a", name: "alpha", depth: 1, status: "completed", parent_id: "root" },
      { id: "g", name: "grand", depth: 2, status: "running", parent_id: "b", replied_since_task: false },
    ]
    current = { id: "b", name: "beta", depth: 1, parent_id: "root" }
    roster = F.build_roster(current, catalog)
    roster["current"].should == { "name" => "beta", "id" => "b", "depth" => 1 }
    roster["entries"].map { |e| e["relationship"] }.should == %w[parent sibling child]
    roster["entries"][0]["name"].should == "root"
    roster["entries"][1]["name"].should == "alpha"
    roster["entries"][2]["name"].should == "grand"
    roster["entries"][2]["replied_since_task"].should.be.false

    # The root sees only children — no parent, and children are not siblings.
    root_roster = F.build_roster({ id: "root", name: "root", depth: 0, parent_id: nil }, catalog)
    root_roster["entries"].map { |e| e["relationship"] }.should == %w[child child]
  end

  it "renders the exact prompt lines and round-trips the message id" do
    prompt = F.build_prompt(
      from: { id: "ka_1", name: "researcher" },
      from_relationship: "child",
      target: { id: "root", name: "root" },
      id: "agentmsg_123",
      message: "the answer is 42",
    )
    prompt.should == "[from child:researcher]\nAgent-to-agent message received.\n" \
                     "Source: agent_message\nFrom: researcher (ka_1)\nTo: root (root)\n" \
                     "Message id: agentmsg_123\n\nthe answer is 42"
    F.parse_prompt_id(prompt).should == "agentmsg_123"
    F.message_prompt?(prompt).should.be.true
    F.message_prompt?("just a user message").should.be.false
  end

  it "omits the receiver name for parent sends and sanitizes metadata" do
    prompt = F.build_prompt(
      from: { id: "ka_9", name: "weird, [name]" }, from_relationship: "parent",
      target: { id: "root", name: "root" }, id: "agentmsg_x", message: "hi",
    )
    prompt.lines.first.should == "[from parent]\n"
    prompt.should.include "weird name (ka_9)"
  end

  it "builds receipts with queuedAt/deliveredAt and steer delivery mode" do
    receipt = F.build_receipt(id: "agentmsg_1", from: { id: "a" }, target: { id: "b" },
                              message: "hi", status: "queued", at: "T")
    receipt["deliveryStatus"].should == "queued"
    receipt["queuedAt"].should == "T"
    receipt["deliveryMode"].should == "steer"
    receipt.key?("deliveredAt").should.be.false
  end

  it "delivers and drains mailboxes without losing concurrent appends" do
    Dir.mktmpdir do |dir|
      F.deliver(dir, "root", { "message" => "one" }).should == 1
      F.deliver(dir, "root", { "message" => "two" }).should == 2
      F.pending_count(dir, "root").should == 2
      drained = F.drain_mailbox(dir, "root")
      drained.map { |m| m["message"] }.should == %w[one two]
      F.pending_count(dir, "root").should == 0
      F.drain_mailbox(dir, "root").should == []
    end
  end

  it "enforces the pending cap" do
    lambda { F.assert_queue_capacity(20) }.should.raise(ArgumentError)
    F.assert_queue_capacity(19).should.be.nil
  end

  it "rate-limits per key with refill and refund" do
    now = 0
    clock = -> { now }
    limiter = F::RateLimiter.new(capacity: 3, refill_ms: 1000, now: clock)
    3.times { limiter.try_consume("a->b")[:ok].should.be.true }
    rejected = limiter.try_consume("a->b")
    rejected[:ok].should.be.false
    rejected[:retry_after_ms].should >= 1
    limiter.try_consume("c->b")[:ok].should.be.true # per-key bucket

    limiter.refund("a->b")
    limiter.try_consume("a->b")[:ok].should.be.true

    limiter.try_consume("a->b") # drain again... now at 0? refund added 1, consumed it
    rejected_again = limiter.try_consume("a->b")
    rejected_again[:ok].should.be.false
    now += 1000
    limiter.try_consume("a->b")[:ok].should.be.true # refilled after one interval
  end
end
