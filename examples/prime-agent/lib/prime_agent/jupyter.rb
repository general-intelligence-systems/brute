# frozen_string_literal: true

require "json"
require "openssl"
require "securerandom"
require "time"

module PrimeAgent
  # Jupyter wire-protocol framing — a Ruby port of the encode/decode/sign
  # trio in prime-agent's KernelManager (packages/coding-agent/src/core/
  # kernel/index.ts:427-478), cross-checked against iruby's own
  # SessionSerialize (references/iruby lib/iruby/session_serializer.rb).
  #
  # A message on the wire is a ZMQ multipart frame sequence:
  #
  #   [idents..., "<IDS|MSG>", hmac_hex, header, parent_header, metadata, content]
  #
  # where the four message frames are compact JSON strings and hmac_hex is the
  # hex HMAC-SHA256 (keyed with the connection file's `key`) over those four
  # frames concatenated in order. Identity frames belong to the ROUTER/DEALER
  # layer and are skipped on decode.
  #
  # Stdlib only: the omq transport is only needed by KernelManager itself.
  module Jupyter
    DELIM = "<IDS|MSG>"
    PROTOCOL_VERSION = "5.3"

    # { header:, parent_header:, metadata:, content: } — symbol keys on build,
    # string keys after decode.
    module Framing
      module_function

      def build_message(msg_type, content, session:, username:)
        {
          header: {
            "msg_id" => SecureRandom.uuid,
            "session" => session,
            "username" => username,
            "date" => Time.now.utc.iso8601,
            "msg_type" => msg_type,
            "version" => PROTOCOL_VERSION,
          },
          parent_header: {},
          metadata: {},
          content: content,
        }
      end

      def sign(parts, key)
        hmac = OpenSSL::HMAC.new(key, OpenSSL::Digest.new("sha256"))
        parts.each { |part| hmac.update(part) }
        hmac.hexdigest
      end

      def encode(message, key)
        parts = [
          JSON.generate(message[:header]),
          JSON.generate(message[:parent_header]),
          JSON.generate(message[:metadata]),
          JSON.generate(message[:content]),
        ]
        [DELIM, sign(parts, key), *parts]
      end

      # Returns a string-keyed hash, or nil for malformed frames. Like
      # prime-agent's decode, the HMAC is not verified — the connection file
      # is 0600 on loopback and the key never leaves the host.
      def decode(frames)
        frames = frames.map(&:to_s)
        index = 0
        index += 1 while index < frames.length && frames[index] != DELIM
        return nil if index + 5 > frames.length - 1

        {
          "header" => JSON.parse(frames[index + 2]),
          "parent_header" => JSON.parse(frames[index + 3]),
          "metadata" => JSON.parse(frames[index + 4]),
          "content" => JSON.parse(frames[index + 5]),
        }
      rescue JSON::ParserError
        nil
      end
    end
  end
end

__END__

describe "prime_agent/jupyter framing" do
  it "encodes DELIM + signature + four JSON frames" do
    message = PrimeAgent::Jupyter::Framing.build_message("kernel_info_request", {}, session: "s", username: "u")
    frames = PrimeAgent::Jupyter::Framing.encode(message, "secret")

    frames.length.should == 6
    frames[0].should == "<IDS|MSG>"
    frames[1].should == PrimeAgent::Jupyter::Framing.sign(frames[2..5], "secret")
    JSON.parse(frames[2])["msg_type"].should == "kernel_info_request"
    JSON.parse(frames[2])["version"].should == "5.3"
  end

  it "matches the HMAC scheme iruby verifies (hex sha256 over the 4 frames)" do
    # Reimplements iruby's SessionSerialize#sign to prove both sides agree.
    parts = %w[header parent metadata content]
    expected = OpenSSL::HMAC.new("key", OpenSSL::Digest.new("sha256")).tap { |h|
      parts.each { |p| h.update(p) }
    }.hexdigest
    PrimeAgent::Jupyter::Framing.sign(parts, "key").should == expected
  end

  it "decode skips identity frames and round-trips" do
    message = PrimeAgent::Jupyter::Framing.build_message("execute_request", { "code" => "1 + 1" },
                                                         session: "s", username: "u")
    frames = PrimeAgent::Jupyter::Framing.encode(message, "k")
    decoded = PrimeAgent::Jupyter::Framing.decode(["identity-a", "identity-b", *frames])

    decoded["header"]["msg_id"].should == message[:header]["msg_id"]
    decoded["content"]["code"].should == "1 + 1"
    decoded["parent_header"].should == {}
  end

  it "decode returns nil for malformed input" do
    PrimeAgent::Jupyter::Framing.decode([]).should.be.nil
    PrimeAgent::Jupyter::Framing.decode(["<IDS|MSG>", "sig", "{"]).should.be.nil
    PrimeAgent::Jupyter::Framing.decode(["<IDS|MSG>", "sig", "{}", "{}", "{}", "{}"])
      .should.not.be.nil
  end
end
