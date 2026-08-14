# frozen_string_literal: true

require "erb"

module PrimeAgent
  # Loads the example's prompt .erb files (prompts/). Prompt text lives in
  # files, not Ruby string literals: static fragments load without locals,
  # templates render locals as ERB local variables. Stdlib-only — this file
  # is also loaded inside the IRuby kernel (via harness_store.rb).
  module Prompts
    DIR = File.expand_path("../../prompts", __dir__)

    module_function

    def load(name, **locals)
      source = File.read(File.join(DIR, "#{name}.erb"))
      context = binding
      locals.each { |key, value| context.local_variable_set(key, value) }
      ERB.new(source, trim_mode: "-").result(context).strip
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/prompts" do
  it "loads a fragment without locals" do
    out = PrimeAgent::Prompts.load("harness_call_contract")
    out.should.include "Ruby REPL skills"
    out.should.not.include "\n"
  end

  it "renders locals as ERB local variables" do
    out = PrimeAgent::Prompts.load("kernel_agent", depth: 3)
    out.should.include "recursive agent depth 3"
  end

  it "raises for a missing prompt file" do
    lambda { PrimeAgent::Prompts.load("no_such_prompt") }.should.raise(Errno::ENOENT)
  end
end
