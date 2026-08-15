# frozen_string_literal: true

require "json"
require "fileutils"

module Hermes
  # The dangerous-command approval gate — port of hermes-agent
  # tools/approval.py's check_dangerous_command + _run_approval_gate.
  #
  # Pipeline order (load-bearing):
  #   1. Hardline blocklist — unconditional, fires BEFORE yolo; can never be approved
  #   2. User deny-globs — also pre-yolo
  #   3. Yolo bypass (HERMES_YOLO_MODE / approvals off)
  #   4. Permanent allowlist (exact or glob; compound commands excluded)
  #   5. Tiered danger-pattern detection (with deobfuscation)
  #   6. Cron/unattended context → auto-deny ("no user present")
  #   7. Smart guardian (optional LLM verdict hook)
  #   8. Human prompt: once/session/always/deny, 300s fail-closed timeout
  #
  # "Silence is not consent": timeout or prompt failure = deny.
  class ApprovalGate
    HARDLINE_PATTERNS = [
      [%r{\brm\s+(-\w*r\w*f|-\w*f\w*r)\s+(-\w+\s+)*-{0,2}\s*/\s*($|[\s'"`;|&])}, "rm -rf / (filesystem wipe)"],
      [%r{\brm\s+(-\w*r\w*f|-\w*f\w*r)\s+(-\w+\s+)*/\*\s*($|[\s'"`;|&])}, "rm -rf /* (filesystem wipe)"],
      [%r{\bmkfs\b}, "mkfs (format a device)"],
      [%r{\bdd\b[^|]*\bof=/dev/}, "dd writing to a device"],
      [%r{\b(shutdown|reboot|halt|poweroff)\b}, "shutdown/reboot"],
      [/:\(\)\s*\{\s*:\|:&\s*\}\s*;:/, "fork bomb"],
      [%r{\bkill\s+-9?\s*-1\b}, "kill all processes"],
    ].freeze

    DANGEROUS_PATTERNS = [
      [%r{\brm\s+(-\w*r\w*f|-\w*f\w*r)\b}, "recursive forced delete (rm -rf)"],
      [%r{\bsudo\b}, "sudo (elevated privileges)"],
      [%r{\bchmod\s+(-\w+\s+)*777\b}, "chmod 777 (world-writable)"],
      [%r{\bchmod\s+-[a-zA-Z]*R[a-zA-Z]*\b}, "recursive chmod"],
      [%r{\bchown\s+-[a-zA-Z]*R[a-zA-Z]*\b}, "recursive chown"],
      [/\|\s*(sudo\s+)?(ba|z|fi)?sh\b/, "piped to shell"],
      [%r{\b(curl|wget)\b[^|;]*\|\s*(sudo\s+)?(ba|z|fi)?sh}, "download piped to shell"],
      [%r{\beval\b}, "eval"],
      [/base64\s+(-d|--decode)[^|]*\|/, "base64-obfuscated execution"],
      [%r{\bmkfs|\bfdisk\b|\bparted\b}, "disk partitioning/format"],
      [%r{\bmount\b|\bumount\b}, "mount/umount"],
      [/\|\s*(sudo\s+)?tee\s+\/etc\//, "writing into /etc"],
      [%r{\bsystemctl\s+(stop|disable|mask)\b}, "systemctl stop/disable/mask"],
      [%r{\bkillall\b|\bpkill\b}, "killall/pkill"],
      [%r{>\s*/dev/(sd[a-z]|nvme|hd[a-z])}, "redirect to device"],
      [%r{\b(crontab\s+-r|visudo)\b}, "cron/sudoers edit"],
      [%r{\bgit\s+push\b[^|]*\s--force\b}, "git push --force"],
    ].freeze

    SHELL_OPERATORS = /[;&|`$()]/

    DENIAL_BREAKER_THRESHOLD = 3

    # prompter: ->(command, description) { "once"|"session"|"always"|"deny"|nil }
    #   nil = no decision (timeout/failure) → fail closed.
    # unattended: cron context — auto-deny dangerous commands, never prompt.
    def initialize(yolo: false, unattended: false, prompter: nil, guardian: nil,
                   allowlist_path: File.join(Dir.pwd, "approvals.json"), deny_globs: [])
      @yolo = yolo || ENV["HERMES_YOLO_MODE"] == "1"
      @unattended = unattended
      @prompter = prompter || method(:default_prompter)
      @guardian = guardian
      @allowlist_path = allowlist_path
      @deny_globs = deny_globs
      @session_allowlist = []
      @consecutive_denials = 0
      @prompt_mutex = Mutex.new
    end

    # Returns { allow: true } or { allow: false, message: }.
    def evaluate(tool:, arguments:)
      command = arguments[:command] || arguments["command"]
      target = command || arguments[:path] || arguments["path"] || arguments[:code] || arguments["code"]
      return allow unless target.is_a?(String)

      # 1. Hardline — unconditional, pre-yolo, never approvable.
      if (hit = HARDLINE_PATTERNS.find { |re, _| re.match?(target) })
        return deny("BLOCKED: '#{target}' matches hardline pattern (#{hit[1]}). " \
                    "This command can never be approved — not by you, not by anyone. " \
                    "Do not retry it or attempt variations.")
      end

      # 2. User deny-globs — pre-yolo.
      if @deny_globs.any? { |glob| File.fnmatch?(glob, target, File::FNM_EXTGLOB) }
        return deny("BLOCKED: '#{target}' is denied by your approvals.deny list.")
      end

      # 3. Yolo bypass.
      return allow if @yolo

      # 4. Permanent allowlist (exact or glob; compound commands excluded from globs).
      return allow if allowlisted?(target)

      # 5. Danger detection (with deobfuscation).
      danger = detect_danger(target)
      return allow unless danger

      # 6. Unattended context — auto-deny; there is no user to ask.
      if @unattended
        return deny("BLOCKED by approval policy: '#{target}' is dangerous (#{danger}) and " \
                    "this session is unattended (cron context). Dangerous commands are " \
                    "auto-denied when no user is present.")
      end

      # 7. Smart guardian (optional LLM verdict): approve/escalate/deny.
      if @guardian
        verdict = @guardian.call(command: target, reason: danger)
        case verdict
        when :approve then return allow
        when :deny    then return record_denial("BLOCKED by smart approval: the guardian denied '#{target}' (#{danger}).")
        end # :escalate falls through to the human
      end

      # 8. Human prompt — blocking, fail-closed on silence.
      prompt_for_decision(target, danger)
    end

    # Direct approval requirement (editor-session writes, plugin escalations):
    # runs the unattended/prompt flow for a target that has already been
    # judged to need a decision.
    def require_approval(target:, reason:)
      if @unattended
        return deny("BLOCKED by approval policy: #{reason} — this session is " \
                    "unattended; approval is auto-denied.")
      end

      prompt_for_decision(target, reason)
    end

    private

    def allow = { allow: true }

    def deny(message) = { allow: false, message: message }

    def allowlisted?(command)
      permanent = load_allowlist
      (permanent + @session_allowlist).any? do |entry|
        next true if entry == command
        next false if command.match?(SHELL_OPERATORS) # compound commands never glob-match

        File.fnmatch?(entry, command, File::FNM_EXTGLOB)
      end
    end

    def detect_danger(command)
      hit = DANGEROUS_PATTERNS.find { |re, _| re.match?(command) }
      hit && hit[1]
    end

    def prompt_for_decision(command, danger)
      choice = @prompt_mutex.synchronize do
        @prompter.call(command, danger)
      rescue StandardError
        nil # prompt failure → fail closed
      end

      case choice
      when "once"
        allow
      when "session"
        @session_allowlist << command
        allow
      when "always"
        persist_allowlist(command)
        allow
      else
        record_denial(
          "BLOCKED by user denial: '#{command}' (#{danger}) was denied " \
          "#{choice.nil? ? 'by timeout — silence is not consent' : 'by the user'}."
        )
      end
    end

    def record_denial(message)
      @consecutive_denials += 1
      if @consecutive_denials >= DENIAL_BREAKER_THRESHOLD
        message += " STOP: #{@consecutive_denials} consecutive denials. Do not attempt " \
                   "further dangerous commands this turn — proceed with a safe approach " \
                   "or report the blocker to the user."
      end
      deny(message)
    end

    def load_allowlist
      return [] unless File.exist?(@allowlist_path)

      Array(JSON.parse(File.read(@allowlist_path))["command_allowlist"])
    rescue JSON::ParserError, SystemCallError
      []
    end

    def persist_allowlist(command)
      list = load_allowlist | [command]
      FileUtils.mkdir_p(File.dirname(@allowlist_path))
      tmp = "#{@allowlist_path}.tmp"
      File.write(tmp, JSON.pretty_generate("command_allowlist" => list))
      File.rename(tmp, @allowlist_path)
    end

    # CLI prompt: show command + reason, read once/session/always/deny with a
    # 300s timeout. Silence is not consent (nil → deny).
    def default_prompter(command, danger)
      require "timeout"
      $stdout.puts "\n⚠️  Dangerous command requires approval:"
      $stdout.puts "  #{command[0, 200]}"
      $stdout.puts "  Reason: #{danger}"
      $stdout.print "  [o]nce / [s]ession / [a]lways / [d]eny (default: deny in 300s): "
      answer = Timeout.timeout(300) { $stdin.gets&.strip&.downcase }
      case answer
      when "o", "once" then "once"
      when "s", "session" then "session"
      when "a", "always" then "always"
      else "deny"
      end
    rescue Timeout::Error, Interrupt
      nil
    end
  end
end
