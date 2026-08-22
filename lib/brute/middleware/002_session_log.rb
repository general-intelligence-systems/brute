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
            loaded << Brute::Message.new(**JSON.parse(line, symbolize_names: true)) unless line.empty?
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

      Brute::Middleware::SessionLog.new(->(e) { e[:messages].assistant("first reply") }, path: path)
        .call({ messages: Brute.log.tap { |l| l.user("hi") } })

      env = { messages: Brute.log.tap { |l| l.user("again") } }
      Brute::Middleware::SessionLog.new(->(e) { }, path: path).call(env)

      File.exist?(path).should.be.true
      env[:messages].map(&:content).should == ["hi", "first reply", "again"]
    end
  end

  it "does not persist the system message" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.jsonl")
      Brute::Middleware::SessionLog.new(->(e) { }, path: path)
        .call({ messages: Brute.log.tap { |l| l.system("secret prompt"); l.user("hi") } })

      File.read(path).should.not.match(/secret prompt/)
    end
  end
end
