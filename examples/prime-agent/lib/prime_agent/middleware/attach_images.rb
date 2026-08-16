# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # AttachImages — per-iteration middleware (wraps ToolPipeline). The
    # delivery half of the attach-image skill (FEATURES.md S3): the skill
    # emits attachment display payloads from the kernel; the KernelManager
    # captures them onto the cell result; the provisioner collects them; and
    # this middleware appends one user message per batch carrying the images
    # as content parts — the port of upstream's imageBlocksFromAttachments
    # (tools/ipython.ts:611-617), which puts ImageContent into the tool
    # result. brute tool results are plain text, so the images head their own
    # user message right after it; the model sees them on the next call.
    #
    # The content-parts array flows through Brute::Message#to_h into the
    # OpenRouter request unchanged.
    class AttachImages
      def initialize(app, provisioner:)
        @app = app
        @provisioner = provisioner
      end

      def call(env)
        @app.call(env)
        deliveries = 0
        loop do
          attachments = @provisioner.drain_attachments
          break if attachments.empty?

          deliveries += 1
          break if deliveries > 8 # defensive: a cell attaching forever

          env[:messages] << Brute::Message.new(role: :user, content: parts_for(attachments))
          # Deliver within the SAME turn: re-invoke so the model sees the
          # images immediately (upstream puts them in the tool result, which
          # keeps the turn alive the same way).
          @app.call(env)
        end
        env
      end

      private

      def parts_for(attachments)
        parts = []
        attachments.each do |attachment|
          label = attachment["path"] || "image"
          parts << { "type" => "text", "text" => "Attached image: #{label} (#{attachment["mime_type"]})" }
          parts << {
            "type" => "image_url",
            "image_url" => { "url" => "data:#{attachment["mime_type"]};base64,#{attachment["data"]}" },
          }
        end
        parts
      end
    end
  end
end

__END__

describe "prime_agent/middleware/attach_images" do
  require "brute/messages"

  it "delivers image parts as a user message and re-invokes within the turn" do
    provisioner = Object.new
    provisioner.define_singleton_method(:drain_attachments) do
      attachments = @attachments || []
      @attachments = []
      attachments
    end
    provisioner.instance_variable_set(:@attachments,
                                      [{ "mime_type" => "image/png", "data" => "aGVsbG8=", "path" => "/tmp/shot.png" }])
    calls = 0
    app = lambda do |env|
      calls += 1
      if calls == 1
        env[:messages].tool("Attached /tmp/shot.png", tool_call_id: "t1")
      else
        env[:messages].assistant("i see it")
      end
      env
    end
    env = { messages: Brute.log }
    PrimeAgent::Middleware::AttachImages.new(app, provisioner: provisioner).call(env)

    calls.should == 2 # the delivery re-invoked the inner stack once
    parts_message = env[:messages][1]
    parts_message.role.should == :user
    parts = parts_message.content
    parts[0].should == { "type" => "text", "text" => "Attached image: /tmp/shot.png (image/png)" }
    parts[1]["type"].should == "image_url"
    parts[1]["image_url"]["url"].should == "data:image/png;base64,aGVsbG8="
    env[:messages].last.role.should == :assistant
  end

  it "is a no-op when nothing was attached" do
    provisioner = Object.new
    provisioner.define_singleton_method(:drain_attachments) { [] }
    app = ->(env) { env[:messages].assistant("plain"); env }
    env = { messages: Brute.log }
    PrimeAgent::Middleware::AttachImages.new(app, provisioner: provisioner).call(env)
    env[:messages].last.role.should == :assistant
  end
end
