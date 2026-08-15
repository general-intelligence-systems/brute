# frozen_string_literal: true

require "brute"

module PrimeAgent
  # The `iruby` tool — the port of prime-agent's single model-facing
  # `ipython` tool (packages/coding-agent/src/core/tools/ipython.ts:
  # 619-704), backed by a persistent IRuby kernel instead of IPython.
  #
  # Like the original, the kernel is single-threaded: KernelManager
  # serializes cells internally, so concurrent tool batches are safe.
  class IrubyTool < Brute::Tool
    ANSI_ESCAPE = /\e\[[0-9;]*m/

    description <<~TXT
      Execute Ruby code in a persistent IRuby kernel — the agent's long-lived notebook. Variables, methods, constants, and loaded data persist across calls. Run shell commands from Ruby with `system`, backticks, or `Open3`; use Ruby (`File`, `FileUtils`, `Dir`, `Find`) for reading, searching, and editing files so results stay bound to named variables. Project imports, tests, scripts, CLIs, and dependency checks should run through the target project's own environment (e.g. `system("bundle exec ...")` from the project root).
    TXT

    param :code,
          type: "string",
          desc: 'Ruby code to execute in the agent kernel. Use the target project\'s own environment for project imports, tests, scripts, CLIs, and dependency checks instead of direct kernel requires.',
          required: true

    def name
      "iruby"
    end

    def initialize(provisioner:)
      @provisioner = provisioner
    end

    def execute(code:)
      format_result(@provisioner.execute(code))
    end

    private

    # Result rendering mirrors the ipython tool: stdout, then stderr, then
    # the result, then the traceback on error (iruby colors traceback frame
    # zero with ANSI escapes — stripped here). Edit-skill diffs come last:
    # prime-agent attaches them to the tool result's `details` for its TUI
    # (kernel/index.ts KernelDiffDisplay); brute tool results are plain text
    # (070_tool_pipeline coerces with to_s), so the diff is rendered into the
    # result — this port's human- and model-visible surface.
    def format_result(result)
      text = result.stdout.to_s.dup
      text += "\n#{result.stderr}" unless result.stderr.to_s.empty?
      text += "\n#{result.result}" if result.result
      result.diffs.each { |diff| text += "\n#{render_diff(diff)}" }
      if result.error
        traceback = Array(result.error["traceback"]).join("\n").gsub(ANSI_ESCAPE, "")
        text += "\n#{traceback}"
      end
      text.empty? ? "(no output)" : text
    end

    # One edit-skill diff display as a +/- block with its absolute start
    # line (upstream's TUI renders the same {path, old_str, new_str,
    # start_line} payload as a gutter diff).
    def render_diff(diff)
      lines = ["diff #{diff["path"]}:#{diff["start_line"]}"]
      diff["old_str"].each_line { |line| lines << "- #{line.chomp}" }
      diff["new_str"].each_line { |line| lines << "+ #{line.chomp}" }
      lines.join("\n")
    end
  end
end

__END__

describe "prime_agent/iruby_tool" do
  Result = PrimeAgent::KernelManager::Result

  def tool_with(result)
    provisioner = Object.new
    provisioner.define_singleton_method(:execute) { |_code, **_| result }
    PrimeAgent::IrubyTool.new(provisioner: provisioner)
  end

  it "advertises name/description/params through the Brute::Tool DSL" do
    tool = PrimeAgent::IrubyTool.new(provisioner: Object.new)
    tool.name.should == "iruby"
    tool.description.should.include "persistent IRuby kernel"
    tool.params[:code][:required].should.be.true
  end

  it "renders stdout, stderr and result like the ipython tool" do
    result = Result.new(stdout: "out", stderr: "err", result: "42",
                        status: "ok", error: nil, duration_ms: 1, diffs: [])
    tool_with(result).call("code" => "40 + 2").should == "out\nerr\n42"
  end

  it "renders edit-skill diffs as a +/- block after the cell output" do
    diff = { "path" => "/abs/a.rb", "old_str" => "two\n", "new_str" => "TWO\n", "start_line" => 2 }
    result = Result.new(stdout: "", stderr: "", result: '"Edited /abs/a.rb"',
                        status: "ok", error: nil, duration_ms: 1, diffs: [diff])
    text = tool_with(result).call("code" => "Edit.run(path: 'a.rb', old_str: 'two', new_str: 'TWO')")
    text.should.include '"Edited /abs/a.rb"'
    text.should.include "diff /abs/a.rb:2"
    text.should.include "- two"
    text.should.include "+ TWO"
  end

  it "renders ANSI-stripped tracebacks on error" do
    result = Result.new(stdout: "", stderr: "", result: nil, status: "error",
                        error: { "traceback" => ["\e[31mRuntimeError\e[0m: boom", "cell:3"] },
                        duration_ms: 1, diffs: [])
    text = tool_with(result).call("code" => "raise 'boom'")
    text.should.include "RuntimeError: boom"
    text.should.not.include "\e[31m"
  end

  it "returns a placeholder for silent cells" do
    result = Result.new(stdout: "", stderr: "", result: nil,
                        status: "ok", error: nil, duration_ms: 1, diffs: [])
    tool_with(result).call("code" => "x = 1").should == "(no output)"
  end
end
