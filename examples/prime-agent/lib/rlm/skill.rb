# frozen_string_literal: true

# Ported from prime-agent-runtime/src/rlm/skill.py (be9e2fa).
#
# Shared CLI helpers for RLM skills. tyro builds a skill function's CLI from
# its signature in Python; the Ruby port maps `--key value`, `--key=value`,
# and bare `--flag` arguments onto keyword arguments of the callable.
module RLM
  module Skill
    module_function

    # Parse CLI arguments for a skill callable and print a non-nil result.
    def run_cli(callable, argv = ARGV, prog: nil)
      result = callable.call(**parse_argv(argv))
      puts result unless result.nil?
      result
    end

    # Run `<skill>.run` for a console script named exactly after the skill.
    def cli(argv = ARGV)
      prog = File.basename($PROGRAM_NAME, ".*")
      begin
        require prog
      rescue LoadError => e
        raise "Could not load skill module #{prog.inspect}. " \
              "The console-script name must match the skill name exactly; " \
              "use underscores instead of dashes. (#{e.message})"
      end

      mod = Object.const_get(prog.split("_").map(&:capitalize).join)
      run = mod.respond_to?(:run) ? mod.method(:run) : nil
      raise "#{prog} does not expose a callable run()" unless run

      run_cli(run, argv, prog: prog)
    end

    # --flag        => { flag: true }
    # --key value   => { key: "value" }
    # --key=value   => { key: "value" }
    # Repeated keys collect into an Array.
    def parse_argv(argv)
      args = {}
      i = 0
      while i < argv.length
        arg = argv[i]
        unless arg.start_with?("--")
          i += 1
          next
        end

        key, eq, inline = arg[2..].partition("=")
        key = key.tr("-", "_").to_sym
        value =
          if !eq.empty?
            inline
          elsif i + 1 < argv.length && !argv[i + 1].start_with?("--")
            i += 1
            argv[i]
          else
            true
          end

        if args.key?(key)
          args[key] = [args[key]] unless args[key].is_a?(Array)
          args[key] << value
        else
          args[key] = value
        end
        i += 1
      end
      args
    end
  end
end

__END__

describe "rlm/skill" do
  it "parses flags, key-values, and inline values" do
    args = RLM::Skill.parse_argv(%w[--path pkg/file.rb --old-str=a --verbose])
    args.should == { path: "pkg/file.rb", old_str: "a", verbose: true }
  end

  it "underscores dashed keys and collects repeats" do
    args = RLM::Skill.parse_argv(%w[--old-str a --old-str b])
    args.should == { old_str: %w[a b] }
  end

  it "run_cli calls the callable and prints a non-nil result" do
    called = nil
    RLM::Skill.run_cli(->(path:, verbose: false) { called = path; nil }, %w[--path x.rb])
    called.should == "x.rb"
  end
end
