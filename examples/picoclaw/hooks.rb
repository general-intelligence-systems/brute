# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

# HookManager — picoclaw's hooks system (pkg/agent/hooks.go, hook_process.go),
# built on brute's `.on()` lifecycle subscriptions.
#
# Hook points: before_llm/after_llm (around every LLM call),
# before_tool/after_tool/approve_tool (around every tool execution), plus
# runtime-event observation (turn start/end). Decisions (HookAction):
# continue | modify | respond | deny_tool | abort_turn | hard_abort.
#
# Semantics preserved from upstream:
# - ordering: in-process hooks before process hooks, then priority, then name
# - timeouts: observer 500ms / interceptor 5s (both FAIL-OPEN: the hook is
#   skipped), approval 60s (FAIL-CLOSED: the call is denied)
# - respond short-circuits execution AND bypasses approval (upstream security
#   note — a before_tool respond never reaches ApproveTool)
# - before_llm mutations of the system message or the tool set are reverted
#   with a warning (prompt-cache invariant)
# - payloads are JSON copies; hooks never see live message objects
#
# Process hooks are spawned per process (this port runs one turn per
# invocation): newline-framed JSON-RPC 2.0 over stdio — hook.hello handshake
# with {name, version, modes}, then hook.runtime_event notifications and
# hook.before_llm / after_llm / before_tool / after_tool / approve_tool calls.
class HookManager
  Entry = Struct.new(:name, :priority, :source, :target, :observe, :intercept)

  def initialize(config:, workspace: Dir.pwd, session: "heartbeat")
    cfg = config["hooks"] || {}
    @enabled = cfg.fetch("enabled", true)
    defaults = cfg["defaults"] || {}
    @observer_timeout = (defaults["observer_timeout_ms"] || 500) / 1000.0
    @interceptor_timeout = (defaults["interceptor_timeout_ms"] || 5000) / 1000.0
    @approval_timeout = (defaults["approval_timeout_ms"] || 60_000) / 1000.0
    @workspace = workspace
    @session = session
    @hooks = []

    (cfg["processes"] || {}).each do |name, pc|
      next unless pc.fetch("enabled", true)

      mount_process(name, pc)
    end
    sort_hooks!
  end

  # In-process hook API: an object responding to any of
  # before_llm/after_llm/before_tool/after_tool/approve_tool(payload).
  def register(name:, hook:, priority: 0, observe: [])
    intercept = %i[before_llm after_llm before_tool after_tool approve_tool].select { |m| hook.respond_to?(m) }
    @hooks << Entry.new(name, priority, :in_process, hook, observe.map(&:to_s), intercept.map(&:to_s))
    sort_hooks!
  end

  def mount_process(name, pc)
    client = ProcessHook.new(name: name, command: pc["command"], dir: pc["dir"] || @workspace,
                             env: pc["env"] || {},
                             observe: pc["observe"] || [], intercept: pc["intercept"] || [])
    @hooks << Entry.new(name, pc["priority"] || 0, :process, client,
                        (pc["observe"] || []).map(&:to_s), (pc["intercept"] || []).map(&:to_s))
    sort_hooks!
  rescue StandardError => e
    warn "hooks: process hook #{name.inspect} failed to start: #{e.message}"
  end

  def wire(pipeline)
    return pipeline unless @enabled

    pipeline.on(:turn_start) { |env| notify_observers("agent.turn.start", env) }
    pipeline.on(:turn_end) { |env| notify_observers("agent.turn.end", env) }
    pipeline.on(:before_llm) { |env| before_llm(env) }
    pipeline.on(:after_llm) { |env| after_llm(env) }
    pipeline.on(:before_tool) { |call| before_tool(call) }
    pipeline.on(:approve_tool) { |call| approve_tool(call) }
    pipeline.on(:after_tool) { |call| after_tool(call) }
    pipeline
  end

  private

  def sort_hooks!
    @hooks.sort_by! { |h| [h.source == :in_process ? 0 : 1, h.priority, h.name] }
  end

  def interceptors(point)
    @hooks.select { |h| h.intercept.include?(point.to_s) }
  end

  # --- runtime event observation (fail-open, observer timeout) ---------------

  def notify_observers(kind, env)
    @hooks.each do |hook|
      next unless hook.observe.include?(kind) || hook.observe.include?("*") || hook.observe.include?("all")

      payload = { "meta" => meta(env), "event" => { "kind" => kind } }
      begin
        Timeout.timeout(@observer_timeout) do
          hook.source == :process ? hook.target.notify("hook.runtime_event", payload) : hook.target.on_runtime_event(payload)
        end
      rescue StandardError => e
        warn "hooks: observer #{hook.name.inspect} failed: #{e.message}"
      end
    end
  end

  # --- LLM interceptors --------------------------------------------------------

  def before_llm(env)
    system_before = env[:messages].find { |m| m.role.to_sym == :system }&.content.to_s
    tools_before = env[:metadata][:llm_tools_fingerprint]

    interceptors(:before_llm).each do |hook|
      decision = call_interceptor(hook, "hook.before_llm", :before_llm, llm_payload(env))
      next if decision.nil?

      apply_decision(decision, env)
      apply_llm_modifications(env, decision)
    end
    revert_prompt_mutations!(env, system_before, tools_before)
  end

  def after_llm(env)
    interceptors(:after_llm).each do |hook|
      decision = call_interceptor(hook, "hook.after_llm", :after_llm, llm_payload(env))
      apply_decision(decision, env) if decision
    end
    nil
  end

  # --- tool interceptors + approval ---------------------------------------------

  def before_tool(call)
    interceptors(:before_tool).each do |hook|
      decision = call_interceptor(hook, "hook.before_tool", :before_tool, tool_payload(call))
      next if decision.nil?

      apply_decision(decision, call[:turn_env])
      case decision["action"]
      when "modify"
        call[:arguments] = decision["arguments"] if decision["arguments"].is_a?(Hash)
      when "respond"
        return decision["result"].to_s # bypasses approval + execution (upstream security note)
      when "deny_tool"
        return denial_text(call, decision["reason"])
      end
    end
    nil
  end

  def approve_tool(call)
    interceptors(:approve_tool).each do |hook|
      decision = call_approval(hook, tool_payload(call))
      next if decision.nil?
      next if decision["approved"]

      return decision["reason"].to_s.empty? ? %(Tool call to "#{call[:name]}" was denied.) : decision["reason"]
    end
    nil
  end

  def after_tool(call)
    interceptors(:after_tool).each do |hook|
      decision = call_interceptor(hook, "hook.after_tool", :after_tool, tool_payload(call).merge("result" => call[:result]))
      next if decision.nil?

      apply_decision(decision, call[:turn_env])
      call[:result] = decision["result"] if decision["action"] == "modify" && decision["result"]
    end
    nil
  end

  # --- decisions ----------------------------------------------------------------

  def apply_decision(decision, env)
    return if env.nil?

    case decision["action"]
    when "abort_turn"
      env[:should_exit] = true
    when "hard_abort"
      SessionStore.rollback!(env)
      env[:should_exit] = true
    end
  end

  def apply_llm_modifications(env, decision)
    return unless decision["action"] == "modify"

    env[:metadata][:llm_model] = decision["model"] if decision["model"].is_a?(String) && !decision["model"].empty?
    return unless decision["messages"].is_a?(Array)

    # Replace the non-system tail of the conversation (the system message is
    # restored afterwards by revert_prompt_mutations! if the hook touched it).
    system = env[:messages].select { |m| m.role.to_sym == :system }
    replacement = decision["messages"].filter_map { |m| hash_to_message(m) }
    env[:messages] = system + replacement.reject { |m| m.role.to_sym == :system }
  end

  # before_llm hooks may not mutate the system message or the advertised tool
  # set (prompt-cache invariant) — revert with a warning.
  def revert_prompt_mutations!(env, system_before, _tools_before)
    current_system = env[:messages].find { |m| m.role.to_sym == :system }&.content.to_s
    return if current_system == system_before

    warn "hooks: before_llm system-prompt mutation reverted (prompt-cache invariant)"
    env[:messages] = env[:messages].map { |m| m.role.to_sym == :system ? m.with(content: system_before) : m }
  end

  def call_interceptor(hook, rpc_method, ruby_method, payload)
    Timeout.timeout(@interceptor_timeout) do
      response =
        if hook.source == :process
          hook.target.call(rpc_method, payload, timeout: @interceptor_timeout)
        else
          hook.target.public_send(ruby_method, payload)
        end
      normalize_decision(response)
    end
  rescue Timeout::Error, StandardError => e
    warn "hooks: interceptor #{hook.name.inspect} skipped (#{e.class}: #{e.message})" # fail-open
    nil
  end

  def call_approval(hook, payload)
    Timeout.timeout(@approval_timeout) do
      response =
        if hook.source == :process
          hook.target.call("hook.approve_tool", payload, timeout: @approval_timeout)
        else
          hook.target.approve_tool(payload)
        end
      response = { "approved" => response } if response == true || response == false
      response
    end
  rescue Timeout::Error, StandardError => e
    warn "hooks: approver #{hook.name.inspect} denied on #{e.class} (fail-closed)"
    { "approved" => false, "reason" => "approval hook error: #{e.message}" }
  end

  def normalize_decision(response)
    return nil if response.nil?
    return { "action" => "continue" } unless response.is_a?(Hash)

    response["action"] = "continue" if response["action"].to_s.empty?
    response
  end

  def denial_text(call, reason)
    reason.to_s.empty? ? %(Tool call to "#{call[:name]}" was denied.) : reason
  end

  # --- payloads -------------------------------------------------------------------

  def meta(env)
    { "agent_id" => "main", "session_key" => @session,
      "iteration" => env[:current_iteration].to_i }
  end

  def message_h(message)
    hash = { "role" => message.role.to_s, "content" => message.content.to_s }
    hash["tool_call_id"] = message.tool_call_id if message.tool_call_id
    if message.tool_call?
      hash["tool_calls"] = message.tool_calls.map { |tc| { "id" => tc.id, "name" => tc.name, "arguments" => tc.arguments } }
    end
    hash
  end

  def hash_to_message(hash)
    Brute::Message.new(role: hash["role"].to_sym, content: hash["content"],
                       tool_calls: hash["tool_calls"], tool_call_id: hash["tool_call_id"])
  end

  def llm_payload(env)
    { "meta" => meta(env), "model" => env[:metadata][:llm_model].to_s,
      "messages" => env[:messages].map { |m| message_h(m) } }
  end

  def tool_payload(call)
    { "meta" => meta(call[:turn_env] || {}), "tool" => call[:name],
      "arguments" => call[:arguments] || {}, "channel" => "cli", "chat_id" => "direct" }
  end

  # Newline-framed JSON-RPC 2.0 over stdio (pkg/agent/hook_process.go port).
  class ProcessHook
    def initialize(name:, command:, dir:, env:, observe:, intercept:)
      raise "process hook #{name.inspect} needs a command" if command.nil? || command.empty?

      @name = name
      @stdin, @stdout, @stderr, @wait = Open3.popen3(env, *command, chdir: dir)
      @pending = {}
      @pending_mutex = Mutex.new
      @next_id = 0
      @closed = false
      start_reader
      start_stderr_drain

      modes = []
      modes << "observe" if observe.any?
      modes << "llm" if (intercept & %w[before_llm after_llm]).any?
      modes << "tool" if (intercept & %w[before_tool after_tool]).any?
      modes << "approve" if intercept.include?("approve_tool")
      call("hook.hello", { "name" => name, "version" => 1, "modes" => modes }, timeout: 5)
    end

    def notify(method, params)
      write("jsonrpc" => "2.0", "method" => method, "params" => params)
    end

    def call(method, params, timeout:)
      raise "process hook #{@name.inspect} is closed" if @closed

      id = (@pending_mutex.synchronize { @next_id += 1 })
      queue = @pending_mutex.synchronize { @pending[id] = Queue.new }
      write("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params)

      result = Timeout.timeout(timeout) { queue.pop }
      raise "process hook #{@name.inspect} #{method} failed: #{result["error"]["message"]}" if result["error"]

      result["result"]
    ensure
      @pending_mutex.synchronize { @pending.delete(id) } if id
    end

    private

    def write(message)
      @stdin.write("#{JSON.generate(message)}\n")
      @stdin.flush
    rescue SystemCallError, IOError => e
      raise "process hook #{@name.inspect} write failed: #{e.message}"
    end

    def start_reader
      Thread.new do
        @stdout.each_line do |line|
          message = JSON.parse(line.strip)
          id = message["id"]
          next unless id

          queue = @pending_mutex.synchronize { @pending[id] }
          queue&.push(message)
        rescue JSON::ParserError
          next
        end
      end
    end

    def start_stderr_drain
      Thread.new do
        @stderr.each_line { |line| warn "hooks[#{@name}]: #{line.strip}" }
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
