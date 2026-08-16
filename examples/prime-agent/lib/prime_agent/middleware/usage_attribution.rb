# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module PrimeAgent
  module Middleware
    # UsageAttribution — per-iteration middleware (inside the loop, wrapping
    # the completion side). The port of prime-agent's usage accounting
    # (core/context-tree.ts computeOwnAndTotalUsage + the per-message
    # accounting that feeds goals/autonomous).
    #
    # The OpenRouter completion middleware records each response's raw usage
    # into env[:metadata][:last_llm_usage]; this middleware normalizes it
    # (OpenAI wire: prompt_tokens/completion_tokens/total_tokens +
    # prompt_tokens_details.cached_tokens; cache_write has no wire field and
    # stays 0) and accumulates per-call sums in env[:metadata][:usage_totals]
    # — exactly upstream's per-message summation, which is what Goal budgets
    # (input+output) and Autonomous limits (input+output+cacheWrite) read.
    # It also publishes env[:metadata][:last_context_tokens] (the last call's
    # total) for Compaction's threshold check — upstream's
    # calculateContextTokens.
    #
    # Every writer (the root run and each KernelAgent child pipeline)
    # publishes its own sums to <bus_dir>/<id>-usage.json; the root run
    # additionally aggregates children into a tree view: `own` excludes
    # descendants, `total` includes them (upstream's own/total rule), so
    # summing the tree never double-counts.
    #
    # Loaded host-side AND into the IRuby kernel (child pipelines) — keep it
    # dependency-free.
    class UsageAttribution
      def initialize(app, bus_dir: nil, agent_id: "root")
        @app = app
        @bus_dir = bus_dir
        @agent_id = agent_id
      end

      def call(env)
        @app.call(env)
        usage = self.class.normalize(env[:metadata] && env[:metadata][:last_llm_usage])
        return env unless usage

        totals = (env[:metadata][:usage_totals] ||= {
          calls: 0, input_sum: 0, output_sum: 0, cache_read_sum: 0, cache_write_sum: 0, total_sum: 0,
        })
        totals[:calls] += 1
        totals[:input_sum] += usage[:input]
        totals[:output_sum] += usage[:output]
        totals[:cache_read_sum] += usage[:cache_read]
        totals[:cache_write_sum] += usage[:cache_write]
        totals[:total_sum] += usage[:total]
        env[:metadata][:last_context_tokens] = usage[:total]
        publish(totals)
        env
      end

      # OpenAI-wire usage -> the port's normalized shape.
      def self.normalize(raw)
        return nil unless raw.is_a?(Hash)

        input = raw["prompt_tokens"] || raw["input_tokens"] || raw[:input] || raw[:prompt_tokens]
        output = raw["completion_tokens"] || raw["output_tokens"] || raw[:output] || raw[:completion_tokens]
        return nil if input.nil? && output.nil?

        cache_read = raw.dig("prompt_tokens_details", "cached_tokens") || raw["cache_read"] || 0
        cache_write = raw["cache_write"] || raw["cache_write_tokens"] || 0
        total = raw["total_tokens"] || (input.to_i + output.to_i + cache_read.to_i + cache_write.to_i)
        {
          input: input.to_i, output: output.to_i,
          cache_read: cache_read.to_i, cache_write: cache_write.to_i, total: total.to_i,
        }
      end

      def self.usage_path(bus_dir, agent_id)
        File.join(bus_dir, "#{agent_id}-usage.json")
      end

      # The family usage tree: one entry per agent id; the root's `total`
      # includes all descendants, `own` never does.
      def self.tree(bus_dir)
        return {} unless bus_dir && File.directory?(bus_dir)

        entries = {}
        Dir.glob(File.join(bus_dir, "*-usage.json")).sort.each do |path|
          id = File.basename(path).sub(/-usage\.json\z/, "")
          entries[id] = JSON.parse(File.read(path))
        rescue JSON::ParserError
          nil
        end
        entries
      end

      private

      def publish(totals)
        return unless @bus_dir

        FileUtils.mkdir_p(@bus_dir)
        own = {
          "calls" => totals[:calls],
          "input" => totals[:input_sum],
          "output" => totals[:output_sum],
          "cache_read" => totals[:cache_read_sum],
          "cache_write" => totals[:cache_write_sum],
          "total" => totals[:total_sum],
        }
        record = { "own" => own, "updated_at" => Time.now.utc.iso8601 }
        if @agent_id == "root"
          children = self.class.tree(@bus_dir).reject { |id, _| id == @agent_id }
          record["children"] = children
          record["total"] = {
            "input" => own["input"] + children.sum { |_, c| c.dig("own", "input").to_i },
            "output" => own["output"] + children.sum { |_, c| c.dig("own", "output").to_i },
            "total" => own["total"] + children.sum { |_, c| c.dig("own", "total").to_i },
          }
        end
        path = self.class.usage_path(@bus_dir, @agent_id)
        tmp = "#{path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(record)}\n")
        File.rename(tmp, path)
      rescue StandardError
        nil # usage reporting must never break a turn
      end
    end
  end
end

__END__

describe "prime_agent/middleware/usage_attribution" do
  require "brute/messages"
  require "tmpdir"

  USAGE = { "prompt_tokens" => 100, "completion_tokens" => 25, "total_tokens" => 125,
            "prompt_tokens_details" => { "cached_tokens" => 40 } }.freeze

  def app_with_usage(usage)
    lambda do |env|
      (env[:metadata] ||= {})[:last_llm_usage] = usage if usage
      env[:messages].assistant("done")
      env
    end
  end

  it "accumulates normalized per-call sums into env metadata" do
    env = { messages: Brute.log }
    middleware = PrimeAgent::Middleware::UsageAttribution.new(app_with_usage(USAGE))
    middleware.call(env)
    middleware.call(env)

    totals = env[:metadata][:usage_totals]
    totals[:calls].should == 2
    totals[:input_sum].should == 200
    totals[:output_sum].should == 50
    totals[:cache_read_sum].should == 80
    totals[:cache_write_sum].should == 0
    totals[:total_sum].should == 250
    env[:metadata][:last_context_tokens].should == 125
  end

  it "publishes the usage file, aggregating children into the root's total" do
    Dir.mktmpdir do |dir|
      # the child publishes first; the root's write aggregates what's there
      PrimeAgent::Middleware::UsageAttribution.new(
        app_with_usage({ "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15 }),
        bus_dir: dir, agent_id: "ka_1",
      ).call({ messages: Brute.log })
      env = { messages: Brute.log }
      PrimeAgent::Middleware::UsageAttribution.new(app_with_usage(USAGE), bus_dir: dir, agent_id: "root").call(env)

      root = JSON.parse(File.read(PrimeAgent::Middleware::UsageAttribution.usage_path(dir, "root")))
      root["own"]["total"].should == 125
      root["children"]["ka_1"]["own"]["total"].should == 15
      root["total"]["total"].should == 140 # 125 + 15, never double-counted
    end
  end

  it "ignores calls without usage and tolerates alternate key shapes" do
    env = { messages: Brute.log }
    PrimeAgent::Middleware::UsageAttribution.new(app_with_usage(nil)).call(env)
    (env[:metadata] || {}).key?(:usage_totals).should.be.false

    alt = app_with_usage({ "input_tokens" => 7, "output_tokens" => 3 })
    env2 = { messages: Brute.log }
    PrimeAgent::Middleware::UsageAttribution.new(alt).call(env2)
    env2[:metadata][:usage_totals][:total_sum].should == 10
  end
end
