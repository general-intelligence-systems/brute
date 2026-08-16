# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module PrimeAgent
  # The in-kernel runtime — loaded INTO the IRuby kernel by the bootstrap
  # cell (see KernelProvisioner / .bootstrap_code). Defines the model-facing
  # namespace as top-level methods available in every cell:
  #
  #   harness            — the continual harness proxy (harness_store.rb)
  #   get_harness_state  — the local store (`global_: true` for the global one)
  #   refine.run(...)    — schedule a /refine pass; runs when the turn ends
  #   refine.status      — pending request info
  #   compact.run(...)   — schedule compaction; runs when the turn ends
  #   compact.status     — context usage {tokens, context_window, percent, scheduled}
  #   rlm_heartbeat.*    — agent-owned recurring instructions (cron_store.rb)
  #   goal.get/create/complete — the persistent thread goal (goal.rb)
  #   agent_message.list_agents/send — the family bus (agent_family.rb)
  #   agent_observe.list_agents/get_agent/recent_messages — read-only views
  #
  # prime-agent's kernel talks to its host over a comm bridge on the Jupyter
  # control channel; iruby's dispatch loop is single-threaded and has no
  # control channel, so the bridge here is a FILE pair per service:
  # `refine.run` atomically writes `<local harness dir>/refine_request.json`
  # (drained by AutoRefine at the next turn boundary) and `compact.run`
  # writes compact_request.json (drained by the Compaction middleware, which
  # publishes compact_status.json back). Harness CRUD needs no bridge at all
  # — both sides read/write harness_state.json directly with mtime re-sync
  # (exactly like prime-agent's Python store).
  #
  # Pure stdlib — this file and harness_store.rb must stay loadable without
  # brute or any gem.
  module KernelRuntime
    # `refine` in the kernel namespace.
    class RefineProxy
      def initialize(request_path:)
        @request_path = request_path
      end

      def run(instructions = nil, global_: false, rollback_id: nil)
        request = {
          "instructions" => instructions,
          "global" => global_ ? true : false,
          "rollback_id" => rollback_id,
          "requested_at" => Time.now.utc.iso8601,
        }
        FileUtils.mkdir_p(File.dirname(@request_path))
        tmp = "#{@request_path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(request)}\n")
        File.rename(tmp, @request_path)
        "Refinement scheduled — it runs when the current turn ends; " \
          "harness changes appear in the system prompt on the next turn."
      end

      def status
        { "pending" => File.exist?(@request_path), "request_path" => @request_path }
      end
    end

    # `compact` in the kernel namespace — the port of prime-agent's bundled
    # `compact` skill (packages/coding-agent/skills/compact): context
    # compaction control from the kernel. Upstream calls the host over a comm
    # bridge (compact.run / compact.status); here the bridge is a FILE pair
    # in the local harness dir: `compact.run` atomically writes
    # compact_request.json, which the host's Compaction middleware drains at
    # the next turn boundary (never mid-cell), and `compact.status` reads
    # compact_status.json, which the middleware publishes every iteration.
    class CompactProxy
      def initialize(request_path:, status_path:)
        @request_path = request_path
        @status_path = status_path
      end

      # Schedule compaction. Returns {"scheduled" => true}; upstream can
      # answer {"scheduled": false, "reason": ...} synchronously from its
      # host bridge — the file bridge can't, so a nothing-to-compact drain
      # no-ops and is observable via #status instead.
      def run(instructions = nil)
        unless instructions.nil? || instructions.is_a?(String)
          raise TypeError, "instructions must be a String or nil, got #{instructions.class}"
        end

        request = {
          "instructions" => instructions,
          "requested_at" => Time.now.utc.iso8601,
        }
        FileUtils.mkdir_p(File.dirname(@request_path))
        tmp = "#{@request_path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(request)}\n")
        File.rename(tmp, @request_path)
        { "scheduled" => true }
      end

      # Current context usage: {"tokens", "context_window", "percent",
      # "scheduled"}. percent is nil right after a compaction until the next
      # model response (published that way by the middleware).
      def status
        base =
          if File.exist?(@status_path)
            begin
              JSON.parse(File.read(@status_path))
            rescue JSON::ParserError
              {}
            end
          else
            {}
          end
        {
          "tokens" => base["tokens"],
          "context_window" => base["context_window"],
          "percent" => base["percent"],
          "scheduled" => File.exist?(@request_path) || base["scheduled"] == true,
        }
      end
    end

    # `rlm_heartbeat` in the kernel namespace — the port of prime-agent's
    # bundled `rlm-heartbeat` skill: agent-owned recurring instructions.
    # Upstream routes these through the host bridge; here the job store is
    # just a JSON file with atomic writes + flock (cron_store.rb), so the
    # proxy writes it DIRECTLY — the dual-writer pattern harness_state.json
    # already uses. The ScheduleDriver claims due jobs between runs.
    class RlmHeartbeatProxy
      def initialize(store_path:)
        @store_path = store_path
      end

      def list(include_inactive: false)
        unless include_inactive == true || include_inactive == false
          raise TypeError, "include_inactive must be true or false"
        end

        store.list_rlm_heartbeats(include_inactive: include_inactive).map { |job| serialize(job) }
      end

      def create(instruction, interval: nil, label: nil, delivery_mode: nil)
        raise TypeError, "instruction must be a String, got #{instruction.class}" unless instruction.is_a?(String)
        validate_optional_string("interval", interval)
        validate_optional_string("label", label)
        validate_optional_string("delivery_mode", delivery_mode)

        serialize(store.create_rlm_heartbeat(
          instruction: instruction, interval: interval, label: label, delivery_mode: delivery_mode,
        ))
      end

      def update(id, instruction: nil, interval: nil, label: nil, status: nil, delivery_mode: nil)
        raise TypeError, "id must be a String, got #{id.class}" unless id.is_a?(String)
        validate_optional_string("instruction", instruction)
        validate_optional_string("interval", interval)
        validate_optional_string("label", label)
        validate_optional_string("status", status)
        validate_optional_string("delivery_mode", delivery_mode)

        serialize(store.update_rlm_heartbeat(
          id, instruction: instruction, interval: interval, label: label,
          status: status, delivery_mode: delivery_mode,
        ))
      end

      def delete(id)
        raise TypeError, "id must be a String, got #{id.class}" unless id.is_a?(String)

        { "deleted" => true, "heartbeat" => serialize(store.delete_rlm_heartbeat(id)) }
      end

      private

      def store
        @store ||= PrimeAgent::CronStore.new(@store_path)
      end

      def validate_optional_string(name, value)
        return if value.nil? || value.is_a?(String)

        raise TypeError, "#{name} must be a String or nil, got #{value.class}"
      end

      # The kernel-facing shape (upstream's rlmHeartbeatHostResponse,
      # agent-session.ts): snake_case, instruction/schedule text.
      def serialize(job)
        {
          "id" => job.id,
          "status" => job.status,
          "label" => job.label,
          "delivery_mode" => job.delivery_mode,
          "instruction" => job.prompt,
          "schedule" => job.schedule["expression"],
          "created_at" => job.created_at,
          "updated_at" => job.updated_at,
          "next_run_at" => job.next_run_at,
          "last_run_at" => job.last_run_at,
          "last_error" => job.last_error,
          "run_count" => job.run_count,
        }
      end
    end

    # `goal` in the kernel namespace — the port of prime-agent's bundled
    # `goal` skill: manage the persistent thread goal from the kernel. All
    # goal state lives in goal.json in the local harness dir; `get` reads it
    # directly (dual-reader, like harness CRUD) and mutations write
    # goal_request.json, which the host's Goal middleware drains at the next
    # turn boundary (never mid-cell).
    class GoalProxy
      def initialize(store_path:, request_path:)
        @store_path = store_path
        @request_path = request_path
      end

      # Current goal: {"goal", "remaining_tokens", "completion_budget_report"}.
      def get
        PrimeAgent::Goal.host_response(PrimeAgent::Goal.load_state(@store_path))
      end

      # Start a new active thread goal. Only when the user or system
      # instructions explicitly ask for a persistent long-running goal — and
      # only when no goal is pending (a completed or errored goal is
      # replaced). Validated here; the middleware applies it at the boundary.
      def create(objective, token_budget: nil)
        raise TypeError, "objective must be a String, got #{objective.class}" unless objective.is_a?(String)
        unless token_budget.nil? || token_budget.is_a?(Integer)
          raise TypeError, "token_budget must be an Integer or nil, got #{token_budget.class}"
        end

        objective = PrimeAgent::Goal.validate_objective(objective)
        token_budget = PrimeAgent::Goal.validate_budget(token_budget)
        state = PrimeAgent::Goal.load_state(@store_path)
        if state.objective && %w[active paused budget_limited].include?(state.status)
          raise "a thread goal is still pending (status: #{state.status}); " \
                "a completed or errored goal can be replaced, a pending one cannot"
        end

        write_request("action" => "create", "objective" => objective, "token_budget" => token_budget)
        { "scheduled" => true }
      end

      # Mark the existing thread goal achieved — only when it actually is.
      def complete
        state = PrimeAgent::Goal.load_state(@store_path)
        if state.objective.nil? || state.status == "idle"
          raise "no thread goal to complete"
        end

        write_request("action" => "complete")
        { "scheduled" => true }
      end

      private

      def write_request(request)
        FileUtils.mkdir_p(File.dirname(@request_path))
        tmp = "#{@request_path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(request.merge("requested_at" => Time.now.utc.iso8601))}\n")
        File.rename(tmp, @request_path)
      end
    end

    # `agent_message` in the kernel namespace — the port of prime-agent's
    # bundled `agent-message` skill: direct messages within the agent's
    # nuclear family (parent, siblings, direct children). Sends append to the
    # target's mailbox file in the shared bus dir; the target's AgentMessages
    # middleware delivers at its next turn boundary, so live-target receipts
    # are "queued". Terminal targets raise — spawn a new child instead.
    class AgentMessageProxy
      # The sender's relationship FROM THE RECEIVER's side (parent↔child).
      SENDER_RELATIONSHIP = { "child" => "parent", "parent" => "child", "sibling" => "sibling" }.freeze

      def initialize(bus_dir:)
        @bus_dir = bus_dir
        @rate_limiter = PrimeAgent::AgentFamily::RateLimiter.new
      end

      def list_agents
        PrimeAgent::AgentFamily.build_roster(KernelAgents.current_entry, KernelAgents.catalog)
      end

      def send(message, broadcast_message = nil, receiver_role: nil, receiver_name: nil)
        unless broadcast_message.nil?
          # Broadcast: send("all", text) fans out to the whole roster with
          # per-target receipts (kernel-side only; direct sends reject "all").
          if receiver_role || receiver_name
            raise TypeError, "broadcast cannot be combined with receiver_role/receiver_name"
          end
          raise ArgumentError, 'broadcast sends use send("all", message)' unless message == "all"

          return { "receipts" => list_agents["entries"].map do |entry|
            begin
              deliver_to(entry, broadcast_message)
            rescue StandardError => error
              { "error" => "#{error.class}: #{error.message}",
                "target" => { "id" => entry["id"], "name" => entry["name"] } }
            end
          end }
        end

        unless PrimeAgent::AgentFamily::RELATIONSHIPS.include?(receiver_role)
          raise ArgumentError, 'receiver_role must be "parent", "sibling", or "child"'
        end
        raise TypeError, "message must be a String, got #{message.class}" unless message.is_a?(String)
        if receiver_role == "parent"
          raise ArgumentError, "receiver_name must be omitted for parent messages" unless receiver_name.nil?
        elsif receiver_name.to_s.strip.empty?
          raise ArgumentError, "receiver_name is required for sibling and child messages"
        end

        wanted = receiver_name.to_s.strip
        matches = list_agents["entries"].select do |entry|
          entry["relationship"] == receiver_role &&
            (receiver_role == "parent" || entry["name"] == wanted || entry["id"] == wanted)
        end
        if matches.empty?
          raise ArgumentError, "no #{receiver_role} named #{wanted.inspect} in the family roster"
        end
        if matches.length > 1
          raise ArgumentError, "ambiguous receiver_name #{wanted.inspect} matches #{matches.length} entries"
        end

        deliver_to(matches.first, message)
      end

      private

      def deliver_to(entry, text)
        if %w[completed error].include?(entry["status"])
          raise "#{entry["name"]} is #{entry["status"]} — spawn a new KernelAgent instead of messaging a finished one"
        end

        normalized = PrimeAgent::AgentFamily.normalize_message(text)
        current = KernelAgents.current_entry
        key = "#{current[:id]}->#{entry["id"]}"
        limit = @rate_limiter.try_consume(key)
        unless limit[:ok]
          raise "agent message rate limit exceeded for #{entry["name"]}; " \
                "retry after #{limit[:retry_after_ms]}ms"
        end

        id = PrimeAgent::AgentFamily.new_message_id
        sender_relationship = SENDER_RELATIONSHIP.fetch(entry["relationship"])
        prompt = PrimeAgent::AgentFamily.build_prompt(
          from: current,
          from_relationship: sender_relationship,
          target: { id: entry["id"], name: entry["name"] },
          id: id,
          message: normalized,
        )
        payload = {
          "id" => id,
          "message" => normalized,
          "from" => { "id" => current[:id], "name" => current[:name] },
          "target" => { "id" => entry["id"], "name" => entry["name"] },
          "prompt" => prompt,
          "sent_at" => Time.now.utc.iso8601,
        }
        begin
          PrimeAgent::AgentFamily.assert_queue_capacity(
            PrimeAgent::AgentFamily.pending_count(@bus_dir, entry["id"]),
          )
          PrimeAgent::AgentFamily.deliver(@bus_dir, entry["id"], payload)
        rescue StandardError
          @rate_limiter.refund(key)
          raise
        end
        Thread.current.thread_variable_get(:kernel_agent)&.mark_replied! if entry["relationship"] == "parent"
        PrimeAgent::AgentFamily.build_receipt(
          id: id,
          from: payload["from"],
          target: payload["target"],
          message: normalized,
          status: "queued",
        )
      end
    end

    # `agent_observe` in the kernel namespace — the port of prime-agent's
    # bundled `agent-observe` skill: read-only family observation. Summaries
    # come from the KernelAgents registry; message previews read the
    # transcript files each agent's AgentObserve middleware publishes.
    class AgentObserveProxy
      def initialize(bus_dir:)
        @bus_dir = bus_dir
      end

      def list_agents
        current = KernelAgents.current_entry
        {
          "current" => summary(current, current: true),
          "agents" => KernelAgents.catalog.reject { |entry| entry[:id] == current[:id] }
                                    .map { |entry| summary(entry) },
        }
      end

      def get_agent(target)
        { "agent" => summary(resolve(target)) }
      end

      # Bounded recent-message previews: limit 1-50 (default 8), max_chars
      # 80-2000 (default 800) — out of range raises, like upstream's host
      # validation.
      def recent_messages(target, limit: 8, max_chars: 800)
        limit = validate_bound("limit", limit, 1, 50)
        max_chars = validate_bound("max_chars", max_chars, 80, 2000)
        entry = resolve(target)
        transcript = read_transcript(entry[:id])
        shown = transcript.last(limit)
        first_index = transcript.length - shown.length
        previews = shown.each_with_index.map do |message, i|
          preview(message, max_chars).merge("index" => first_index + i)
        end
        {
          "agent" => summary(entry),
          "messages" => previews,
          "limit" => limit,
          "max_chars" => max_chars,
          "truncated" => transcript.length > shown.length,
        }
      end

      private

      def validate_bound(name, value, min, max)
        raise TypeError, "#{name} must be an Integer, got #{value.class}" unless value.is_a?(Integer)
        if value < min || value > max
          raise ArgumentError, "#{name} must be between #{min} and #{max}"
        end

        value
      end

      # Resolve by id, name, or unambiguous suffix (upstream's target rules).
      def resolve(target)
        raise TypeError, "target must be a String, got #{target.class}" unless target.is_a?(String)

        matches = KernelAgents.catalog.select do |entry|
          entry[:id] == target || entry[:name] == target ||
            entry[:id].end_with?(target) || (entry[:name] && entry[:name].end_with?(target))
        end
        raise "no agent matches #{target.inspect}" if matches.empty?
        raise "ambiguous target #{target.inspect}" if matches.length > 1

        matches.first
      end

      def summary(entry, current: false)
        transcript = read_transcript(entry[:id])
        summary = {
          "id" => entry[:id],
          "name" => entry[:name],
          "depth" => entry[:depth],
          "runtime_kind" => entry[:id] == "root" ? "top-level" : "subagent",
          "status" => activity_status(entry),
          "parent_id" => entry[:parent_id],
          "is_current" => current,
          "message_count" => transcript.length,
          "first_message" => transcript.first && preview(transcript.first, 240),
          "latest_message" => transcript.last && preview(transcript.last, 240),
        }
        summary["replied_since_task"] = entry[:replied_since_task] unless entry[:replied_since_task].nil?
        summary
      end

      # Upstream computes tool|model|compacting|busy|user|idle from live
      # session state; our agents are threads: running -> busy, terminal -> idle.
      def activity_status(entry)
        entry[:status] == "running" ? "busy" : "idle"
      end

      def preview(message, max_chars)
        text = message["content"].to_s
        truncated = text.length > max_chars
        preview = {
          "role" => message["role"],
          "text" => truncated ? text[0...max_chars] : text,
          "truncated" => truncated,
        }
        calls = message["tool_calls"]
        preview["toolCalls"] = calls if calls && !calls.empty?
        preview
      end

      def read_transcript(agent_id)
        path = PrimeAgent::AgentFamily.transcript_path(@bus_dir, agent_id)
        return [] unless File.exist?(path)

        data = JSON.parse(File.read(path))
        data.is_a?(Array) ? data : []
      rescue JSON::ParserError
        []
      end
    end

    # ------------------------------------------------------------------
    # Kernel state snapshots (M17) — the port of prime-agent's dill-based
    # namespace snapshot/restore (core/kernel/state-snapshot.ts +
    # kernel/index.ts). Ruby has no dill: each top-level local/ivar is
    # Marshalled individually so undumpable values (IO, threads, procs) are
    # dropped and reported rather than failing the snapshot, and each value
    # is individually re-loadable at restore (a now-undefined class drops
    # just that name). Requires the model made under skill lib dirs are
    # recorded and re-required — the port's "imports persist".
    #
    # These run IN the kernel; the provisioner drives them with the cell's
    # binding (the persistent workspace binding).
    # ------------------------------------------------------------------

    def self.snapshot_state(eval_binding, path, manifest_path: nil, max_bytes: 256 * 1024 * 1024)
      saved = {}
      dropped = []

      eval_binding.local_variables.each do |name|
        begin
          saved[name.to_s] = Marshal.dump(eval_binding.local_variable_get(name))
        rescue StandardError
          dropped << name.to_s
        end
      end
      main = eval_binding.receiver
      main.instance_variables.each do |ivar|
        begin
          saved[ivar.to_s] = Marshal.dump(main.instance_variable_get(ivar))
        rescue StandardError
          dropped << ivar.to_s
        end
      end
      requires = $LOADED_FEATURES.select { |f| f.include?("/.brute/skills/") }

      payload = Marshal.dump("locals_ivars" => saved, "requires" => requires)
      if payload.bytesize > max_bytes
        return "snapshot skipped: #{payload.bytesize} bytes exceeds the #{max_bytes} cap"
      end

      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.binwrite(tmp, payload)
      File.rename(tmp, path)
      if manifest_path
        File.write("#{manifest_path}.#{Process.pid}.tmp",
                   JSON.pretty_generate("saved_at" => Time.now.utc.iso8601, "saved" => saved.keys, "dropped" => dropped))
        File.rename("#{manifest_path}.#{Process.pid}.tmp", manifest_path)
      end
      "snapshot: saved #{saved.size} names" + (dropped.empty? ? "" : ", dropped #{dropped.join(", ")}")
    end

    # Restore is CODEGEN, not a runtime call: only source-level assignments
    # persist across iruby cells (binding.local_variable_set / binding.eval
    # land in the eval frame and vanish — iruby's workspace only keeps
    # assignments from cell source). So the bootstrap cell embeds one
    # assignment per saved name, values as base64'd Marshal blobs; names that
    # no longer load (e.g. an undefined class) rescue to nil — the save-time
    # manifest is the drop report. Runs BEFORE install!, so the runtime's
    # live proxies shadow restored names (upstream's order).
    def self.restore_code(path)
      return "# no kernel snapshot to restore" unless File.exist?(path)

      data =
        begin
          Marshal.load(File.binread(path))
        rescue StandardError
          return "# kernel snapshot unreadable"
        end
      lines = ["# restored from the kernel snapshot"]
      data.fetch("locals_ivars", {}).each do |name, blob|
        valid = name.match?(/\A@[a-z_][a-zA-Z0-9_]*\z/) || name.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)
        next unless valid

        lines << %(#{name} = (Marshal.load("#{[blob].pack("m0")}".unpack1("m0")) rescue nil))
      end
      data.fetch("requires", []).each do |feature|
        lines << %(begin; require #{feature.inspect}; rescue LoadError; end)
      end
      lines.join("\n")
    end

    # ------------------------------------------------------------------
    # Orphan journal (M20) — the port of prime-agent's
    # orphan-process-journal.ts. Cells spawn processes with plain Ruby, so
    # the journal hook is a Process.spawn wrapper installed at bootstrap:
    # every spawned pid is journaled with its /proc start-time identity (so
    # a recycled pid is never killed), and the host's OrphanReaper middleware
    # group-SIGKILLs the live ones at run end.
    module SpawnJournal
      def spawn(*args, **kwargs)
        pid = super
        PrimeAgent::KernelRuntime.journal_orphan(pid)
        pid
      end
    end

    def self.journal_orphan(pid, path = @orphan_journal_path)
      return unless path

      start_id =
        begin
          File.read("/proc/#{pid}/stat").split[21] # field 22: starttime (Linux)
        rescue StandardError
          nil
        end
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write("#{JSON.generate("pid" => pid, "start_id" => start_id, "at" => Time.now.utc.iso8601)}\n")
      end
    rescue StandardError
      nil # process tracking must never fail a spawn
    end

    # The bootstrap cell executed right after the kernel boots. Paths are
    # interpolated as Ruby literals via #inspect.
    def self.bootstrap_code(harness_store_path:, local_dir:, global_dir:, request_path:, skill_lib_glob: nil,
                            kernel_agents_path: File.expand_path("kernel_agents.rb", __dir__),
                            cron_store_path: File.expand_path("cron_store.rb", __dir__),
                            goal_path: File.expand_path("goal.rb", __dir__),
                            agent_family_path: File.expand_path("agent_family.rb", __dir__),
                            model_registry_path: File.expand_path("model_registry.rb", __dir__),
                            mcp_path: File.expand_path("mcp.rb", __dir__),
                            bus_middleware_glob: File.expand_path("middleware/{agent_messages,agent_observe,usage_attribution}.rb", __dir__),
                            snapshot_path: nil,
                            bundle_gemfile: File.expand_path("../../Gemfile", __dir__))
      <<~RUBY
        load #{File.expand_path(harness_store_path).inspect}
        load #{File.expand_path(__FILE__).inspect}
        load #{File.expand_path(kernel_agents_path).inspect}
        load #{File.expand_path(cron_store_path).inspect}
        load #{File.expand_path(goal_path).inspect}
        load #{File.expand_path(agent_family_path).inspect}
        load #{File.expand_path(model_registry_path).inspect}
        load #{File.expand_path(mcp_path).inspect}
        Dir.glob(#{bus_middleware_glob.inspect}).each { |file| load file }
        #{snapshot_path ? restore_code(File.expand_path(snapshot_path)) : "# snapshots disabled"}
        PrimeAgent::KernelRuntime.install!(
          harness_store_path: #{File.expand_path(harness_store_path).inspect},
          local_dir: #{local_dir.inspect},
          global_dir: #{global_dir.inspect},
          request_path: #{request_path.inspect},
          skill_lib_glob: #{skill_lib_glob.inspect},
          kernel_agents_path: #{File.expand_path(kernel_agents_path).inspect},
          cron_store_path: #{File.expand_path(cron_store_path).inspect},
          goal_path: #{File.expand_path(goal_path).inspect},
          agent_family_path: #{File.expand_path(agent_family_path).inspect},
          model_registry_path: #{File.expand_path(model_registry_path).inspect},
          mcp_path: #{File.expand_path(mcp_path).inspect},
          bundle_gemfile: #{bundle_gemfile.inspect}
        )
        "prime-agent kernel runtime ready"
      RUBY
    end

    def self.install!(local_dir:, global_dir:, request_path:, harness_store_path:, skill_lib_glob: nil,
                      kernel_agents_path: nil, cron_store_path: nil, goal_path: nil,
                      agent_family_path: nil, model_registry_path: nil, mcp_path: nil, bundle_gemfile: nil)
      load harness_store_path unless defined?(PrimeAgent::HarnessStore)
      load cron_store_path if cron_store_path && !defined?(PrimeAgent::CronStore)
      load goal_path if goal_path && !defined?(PrimeAgent::Goal)
      load agent_family_path if agent_family_path && !defined?(PrimeAgent::AgentFamily)
      load model_registry_path if model_registry_path && !defined?(PrimeAgent::ModelRegistry)
      load mcp_path if mcp_path && !defined?(PrimeAgent::Mcp)

      harness = PrimeAgent::Harness.new(
        local_store: PrimeAgent::HarnessStore.new(local_dir, scope: "local"),
        global_store: PrimeAgent::HarnessStore.new(global_dir, scope: "global"),
      )
      refine = RefineProxy.new(request_path: request_path)
      compact = CompactProxy.new(
        request_path: File.join(local_dir, "compact_request.json"),
        status_path: File.join(local_dir, "compact_status.json"),
      )
      rlm_heartbeat = RlmHeartbeatProxy.new(store_path: File.join(local_dir, "scheduled-jobs.json"))
      goal = GoalProxy.new(
        store_path: File.join(local_dir, "goal.json"),
        request_path: File.join(local_dir, "goal_request.json"),
      )
      bus_dir = File.join(local_dir, "agent_bus")
      agent_message = AgentMessageProxy.new(bus_dir: bus_dir)
      agent_observe = AgentObserveProxy.new(bus_dir: bus_dir)
      PrimeAgent::KernelAgents.bus_dir = bus_dir if kernel_agents_path

      @orphan_journal_path = File.join(local_dir, "orphans.jsonl")
      Process.singleton_class.prepend(SpawnJournal) unless Process.singleton_class < SpawnJournal

      Array(skill_lib_glob).compact.each do |glob|
        Dir.glob(glob).each { |dir| $LOAD_PATH.unshift(dir) unless $LOAD_PATH.include?(dir) }
      end

      if kernel_agents_path
        load kernel_agents_path unless defined?(PrimeAgent::KernelAgents)
        PrimeAgent::KernelAgents.bundle_gemfile = bundle_gemfile
        Object.const_set(:KernelAgent, PrimeAgent::KernelAgents) unless defined?(::KernelAgent)
      end

      runtime = Module.new do
        define_method(:harness) { harness }
        define_method(:refine) { refine }
        define_method(:compact) { compact }
        define_method(:rlm_heartbeat) { rlm_heartbeat }
        define_method(:goal) { goal }
        define_method(:agent_message) { agent_message }
        define_method(:agent_observe) { agent_observe }
        define_method(:get_harness_state) { |global_: false| harness.get_harness_state(global_: global_) }
      end
      Object.include(runtime)
      harness
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/kernel_runtime" do
  it "RefineProxy#run writes the request file atomically; #status reports it" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "refine_request.json")
      proxy = PrimeAgent::KernelRuntime::RefineProxy.new(request_path: path)

      proxy.status["pending"].should.be.false
      message = proxy.run("save the rg lesson", global_: false)
      message.should.include "Refinement scheduled"
      proxy.status["pending"].should.be.true

      request = JSON.parse(File.read(path))
      request["instructions"].should == "save the rg lesson"
      request["global"].should == false
      request["rollback_id"].should.be.nil
      request["requested_at"].should.not.be.nil
    end
  end

  it "CompactProxy#run writes the request file; #status reads the published status" do
    Dir.mktmpdir do |dir|
      request_path = File.join(dir, "compact_request.json")
      status_path = File.join(dir, "compact_status.json")
      proxy = PrimeAgent::KernelRuntime::CompactProxy.new(request_path: request_path, status_path: status_path)

      proxy.status.should == { "tokens" => nil, "context_window" => nil, "percent" => nil, "scheduled" => false }
      proxy.run("keep the failing tests").should == { "scheduled" => true }
      proxy.status["scheduled"].should.be.true
      JSON.parse(File.read(request_path))["instructions"].should == "keep the failing tests"

      File.write(status_path, JSON.generate("tokens" => 100, "context_window" => 1000,
                                            "percent" => 10.0, "scheduled" => false))
      proxy.status["percent"].should == 10.0
      proxy.status["scheduled"].should.be.true # the pending request wins

      lambda { proxy.run(123) }.should.raise(TypeError)
    end
  end

  it "RlmHeartbeatProxy does CRUD against the store file in the kernel-facing shape" do
    Dir.mktmpdir do |dir|
      proxy = PrimeAgent::KernelRuntime::RlmHeartbeatProxy.new(
        store_path: File.join(dir, "scheduled-jobs.json"),
      )
      created = proxy.create("check the test run", interval: "5m", label: "tests")
      created["status"].should == "active"
      created["instruction"].should == "check the test run"
      created["schedule"].should == "5m" # expressions are stored verbatim
      created["delivery_mode"].should == "steer"
      created["run_count"].should == 0

      proxy.list.map { |h| h["label"] }.should == ["tests"]
      proxy.update(created["id"], status: "pause")["status"].should == "paused"
      proxy.list.should == []
      proxy.list(include_inactive: true).length.should == 1
      proxy.delete(created["id"])["deleted"].should.be.true
      proxy.list(include_inactive: true).should == []

      lambda { proxy.create(42) }.should.raise(TypeError)
      lambda { proxy.update(created["id"], status: "explode") }.should.raise(ArgumentError)
    end
  end

  it "GoalProxy validates, schedules create/complete, and reads state back" do
    require_relative "goal"
    Dir.mktmpdir do |dir|
      store_path = File.join(dir, "goal.json")
      proxy = PrimeAgent::KernelRuntime::GoalProxy.new(
        store_path: store_path, request_path: File.join(dir, "goal_request.json"),
      )

      proxy.get.should == { "goal" => nil, "remaining_tokens" => nil, "completion_budget_report" => nil }
      lambda { proxy.complete }.should.raise(RuntimeError) # no goal to complete

      proxy.create("ship the release", token_budget: 5000).should == { "scheduled" => true }
      request = JSON.parse(File.read(File.join(dir, "goal_request.json")))
      request["action"].should == "create"
      request["objective"].should == "ship the release"

      # The store itself is untouched until the middleware drains the request;
      # a completed/errored goal is replaceable, a pending one is not.
      PrimeAgent::Goal.save_state(store_path, PrimeAgent::Goal.load_state(store_path))
      lambda { proxy.create(42) }.should.raise(TypeError)
      lambda { proxy.create("x" * 4001) }.should.raise(ArgumentError)
      lambda { proxy.create("ok", token_budget: 0) }.should.raise(ArgumentError)

      PrimeAgent::Goal.create_in_store(store_path, objective: "active goal")
      lambda { proxy.create("another") }.should.raise(RuntimeError) # pending
      proxy.complete.should == { "scheduled" => true }
      JSON.parse(File.read(File.join(dir, "goal_request.json")))["action"].should == "complete"
    end
  end

  it "AgentMessageProxy routes family messages with validation, limits, and receipts" do
    require_relative "agent_family"
    require_relative "kernel_agents"
    Dir.mktmpdir do |dir|
      KA = PrimeAgent::KernelAgents
      KA.terminal = ->(env) { env[:messages].assistant("ok"); env }
      KA.spawn("done", name: "ghost").thread.join(5)
      KA.terminal = ->(env) { sleep 30; env }
      live = KA.spawn("quick", name: "kid") # still running when we message it

      proxy = PrimeAgent::KernelRuntime::AgentMessageProxy.new(bus_dir: dir)
      roster = proxy.list_agents
      roster["current"].should == { "name" => "root", "id" => "root", "depth" => 0 }
      roster["entries"].map { |e| e["name"] }.should.include "kid"

      receipt = proxy.send("hello kid", receiver_role: "child", receiver_name: "kid")
      receipt["deliveryStatus"].should == "queued"
      receipt["deliveryMode"].should == "steer"
      receipt["id"].should.start_with "agentmsg_"
      mailbox = PrimeAgent::AgentFamily.drain_mailbox(dir, live.id)
      mailbox.length.should == 1
      mailbox.first["prompt"].should.include "[from parent]\n"
      mailbox.first["prompt"].should.include "From: root (root)"
      mailbox.first["prompt"].should.include "Message id: agentmsg_"

      lambda { proxy.send("boo", receiver_role: "child", receiver_name: "ghost") }
        .should.raise(RuntimeError) # terminal children can't receive
      lambda { proxy.send("up", receiver_role: "parent") }.should.raise(ArgumentError) # root has none
      lambda { proxy.send("   ", receiver_role: "child", receiver_name: "kid") }.should.raise(ArgumentError)
      lambda { proxy.send("x", receiver_role: "child") }.should.raise(ArgumentError) # name required
      lambda { proxy.send("x", receiver_role: "stranger") }.should.raise(ArgumentError)

      live.stop!
      live.thread.join(5)
    ensure
      PrimeAgent::KernelAgents.terminal = nil
    end
  end

  it "AgentMessageProxy broadcasts with per-target receipts" do
    require_relative "agent_family"
    require_relative "kernel_agents"
    Dir.mktmpdir do |dir|
      KA = PrimeAgent::KernelAgents
      KA.terminal = ->(env) { sleep 30; env }
      KA.spawn("one", name: "b1")
      KA.spawn("two", name: "b2")
      proxy = PrimeAgent::KernelRuntime::AgentMessageProxy.new(bus_dir: dir)
      result = proxy.send("all", "family meeting")
      ours = result["receipts"].select { |r| %w[b1 b2].include?(r.dig("target", "name")) }
      ours.length.should == 2 # (the registry accumulates across this file's specs)
      ours.all? { |r| r["deliveryStatus"] == "queued" }.should.be.true
      lambda { proxy.send("all", "x", receiver_role: "child") }.should.raise(TypeError)
      KA.stop("b1")
      KA.stop("b2")
    ensure
      PrimeAgent::KernelAgents.terminal = nil
    end
  end

  it "AgentObserveProxy summarizes and previews transcripts with bounds" do
    require_relative "agent_family"
    require_relative "kernel_agents"
    Dir.mktmpdir do |dir|
      KA = PrimeAgent::KernelAgents
      KA.terminal = ->(env) { env[:messages].assistant("child answer"); env }
      KA.spawn("research", name: "watcher").thread.join(5)
      PrimeAgent::AgentFamily.transcript_path(dir, "root").tap do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate([{ "role" => "user", "content" => "root task" }]))
      end

      proxy = PrimeAgent::KernelRuntime::AgentObserveProxy.new(bus_dir: dir)
      listed = proxy.list_agents
      listed["current"]["id"].should == "root"
      listed["current"]["latest_message"]["text"].should == "root task"
      agent = listed["agents"].find { |a| a["name"] == "watcher" }
      agent["status"].should == "idle" # terminal child
      agent["runtime_kind"].should == "subagent"

      proxy.get_agent("watcher")["agent"]["name"].should == "watcher" # name resolution
      lambda { proxy.get_agent("nobody") }.should.raise(RuntimeError)

      lambda { proxy.recent_messages("watcher", limit: 0) }.should.raise(ArgumentError)
      lambda { proxy.recent_messages("watcher", max_chars: 10) }.should.raise(ArgumentError)
      lambda { proxy.recent_messages("watcher", limit: 2.5) }.should.raise(TypeError)
      recent = proxy.recent_messages("watcher", limit: 8, max_chars: 800)
      recent["truncated"].should.be.false
      recent["limit"].should == 8
    ensure
      PrimeAgent::KernelAgents.terminal = nil
    end
  end

  # A pristine top-level binding (instance_eval bindings close over their
  # enclosing locals; a fresh method scope does not).
  def clean_binding
    Object.new.instance_eval { binding }
  end

  it "snapshot_state/restore_state round-trip dumpable names and report the rest" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snap.marshal")
      manifest = "#{path}.json"

      source = clean_binding
      source.local_variable_set(:answer, 42)
      source.local_variable_set(:proc_thing, ->(x) { x }) # Procs can't Marshal
      Object.const_set(:SnapTmpKlass, Class.new)
      source.local_variable_set(:weird, SnapTmpKlass.new)

      out = PrimeAgent::KernelRuntime.snapshot_state(source, path, manifest_path: manifest)
      out.should.include "saved 2 names"
      out.should.include "dropped proc_thing"
      JSON.parse(File.read(manifest))["saved"].should.include "answer"

      Object.send(:remove_const, :SnapTmpKlass) # now unloadable at restore
      target = clean_binding
      target.eval(PrimeAgent::KernelRuntime.restore_code(path))
      target.local_variable_get(:answer).should == 42
      target.local_variable_get(:weird).should.be.nil # un-loadable names restore as nil

      PrimeAgent::KernelRuntime.restore_code(File.join(dir, "nope")).should == "# no kernel snapshot to restore"
    end
  end

  it "bootstrap_code embeds the runtime paths as Ruby literals" do
    code = PrimeAgent::KernelRuntime.bootstrap_code(
      harness_store_path: "lib/prime_agent/harness_store.rb",
      local_dir: "/tmp/local",
      global_dir: "/tmp/global",
      request_path: "/tmp/local/refine_request.json",
      skill_lib_glob: "/work/.brute/skills/*/lib",
    )
    code.should.include 'load "'
    code.should.include "harness_store.rb"
    code.should.include "kernel_runtime.rb"
    code.should.include 'local_dir: "/tmp/local"'
    code.should.include 'global_dir: "/tmp/global"'
    code.should.include 'request_path: "/tmp/local/refine_request.json"'
    code.should.include 'skill_lib_glob: "/work/.brute/skills/*/lib"'
  end
end
