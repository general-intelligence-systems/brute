# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"
require "fileutils"

module Brute
  module Middleware
    # The "session" is just a JSONL log of the conversation on disk. This
    # middleware owns that log — there is no Session class.
    #
    #   in  -> if the file exists, prepend its messages to env[:messages] so
    #          this turn continues the prior conversation.
    #   out <- write the log back to disk (skipping the :system message, which
    #          the SystemPrompt middleware re-adds each turn).
    #
    # Put it near the top of the stack (outermost) so history is loaded before
    # the rest of the middleware runs and the whole turn is persisted after:
    #
    #   Brute.agent
    #     .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
    #     .use(Brute::Middleware::SystemPrompt)
    #     ...
    #
    class SessionLog
      def initialize(app, path:)
        @app  = app
        @path = path
      end

      def call(env)
        load_into(env[:messages]) if @path && File.exist?(@path)
        @app.call(env)
        persist(env[:messages]) if @path
        env
      end

      private

        def load_into(messages)
          loaded = []
          File.foreach(@path) do |line|
            line = line.strip
            loaded << ::RubyLLM::Message.new(**JSON.parse(line, symbolize_names: true)) unless line.empty?
          end
          messages.unshift(*loaded)
        end

        def persist(messages)
          FileUtils.mkdir_p(File.dirname(@path))
          File.open(@path, "w") do |f|
            messages.each do |message|
              next if message.role == :system

              f.puts(JSON.generate(message.to_h))
            end
          end
        end
    end
  end
end

__END__

describe "brute/middleware/002_session_log" do
  require "brute/messages"
  require "tmpdir"

  it "persists the log and reloads it on the next turn" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.jsonl")

      # Turn 1: no file yet; terminal appends an assistant reply.
      turn = ->(env) { env[:messages].assistant("first reply") }
      Brute::Middleware::SessionLog.new(turn, path: path).call(
        { messages: Brute.log.tap { |l| l.user("hi") } }
      )

      File.exist?(path).should.be.true

      # Turn 2: fresh log with a new user message; history is prepended.
      env = { messages: Brute.log.tap { |l| l.user("again") } }
      Brute::Middleware::SessionLog.new(->(e) { }, path: path).call(env)

      env[:messages].map(&:content).should == ["hi", "first reply", "again"]
    end
  end

  it "does not persist the system message" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "s.jsonl")
      env = { messages: Brute.log.tap { |l| l.system("secret prompt"); l.user("hi") } }
      Brute::Middleware::SessionLog.new(->(e) { }, path: path).call(env)

      reloaded = File.readlines(path).map(&:strip).reject(&:empty?)
      reloaded.any? { |line| line.include?("secret prompt") }.should.be.false
    end
  end
end
