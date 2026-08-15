# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # AgentMessages — per-turn middleware. SCAFFOLD: pass-through no-op
    # (FEATURES.md M6, skill S9).
    #
    # Ports prime-agent `packages/coding-agent/src/core/agent-messages.ts`:
    # the agent-to-agent family bus. "Nuclear family" roster only: parent,
    # siblings (same depth+parent), direct children; session-name uniqueness
    # per (depth, parent) scope. Sends resolve exactly one roster match;
    # delivery is ALWAYS steer (the auto/steer/follow_up input is
    # legacy-ignored); a busy target gets the message queued with receipt
    # "queued" (never await — mutual sends must not deadlock), an idle one
    # "delivered". Injected message: agent_message custom type
    # ("[from <relationship>[:<name>]] ... Message id: agentmsg_<uuid>")
    # flattened to a user message. Broadcast send("all", msg) fans out with
    # per-target receipts — kernel-side only.
    # Limits: message 16_384 chars; 20 pending per session; rate limit token
    # bucket 3 tokens / 1000 ms per sender->target pair (refunded on failure).
    #
    # Fill-in: owns the roster + mailboxes and drains inbound messages at
    # turn boundaries; the kernel-side AgentMessage skill drives it via
    # agent_message.list_agents / agent_message.send request files.
    class AgentMessages
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end

__END__

describe "prime_agent/middleware/agent_messages" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::AgentMessages.new(app).call(env)
    env[:inner].should.be.true
  end
end
