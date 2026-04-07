# frozen_string_literal: true

RSpec.describe Brute::Tools::Delegate do
  let(:provider) { MockProvider.new }

  # Simple stand-in for LLM::Message in context history.
  FakeMessage = Struct.new(:role, :content) do
    def assistant?
      role == :assistant
    end
  end

  before do
    allow(Brute).to receive(:provider).and_return(provider)
  end

  def fake_context(messages)
    msgs_obj = Object.new
    msgs_obj.define_singleton_method(:to_a) { messages }
    ctx = Object.new
    ctx.define_singleton_method(:messages) { msgs_obj }
    ctx
  end

  describe "#call" do
    it "returns the sub-agent's text content" do
      result = described_class.new.call(task: "What files exist?")
      expect(result).to be_a(Hash)
      expect(result[:result]).to eq("mock response")
    end
  end

  describe "#extract_content" do
    let(:delegate) { described_class.new }

    it "returns content when response has text" do
      res = MockResponse.new(content: "analysis complete")
      context = fake_context([])
      result = delegate.send(:extract_content, res, context)
      expect(result).to eq("analysis complete")
    end

    context "when res.content raises NoMethodError (tool-only response)" do
      let(:bad_res) do
        obj = Object.new
        obj.define_singleton_method(:content) do
          raise NoMethodError, "undefined method 'content' for nil"
        end
        obj
      end

      it "falls back to the last assistant text in context messages" do
        context = fake_context([
          FakeMessage.new(:user, "input"),
          FakeMessage.new(:assistant, "found the answer"),
        ])

        result = delegate.send(:extract_content, bad_res, context)
        expect(result).to eq("found the answer")
      end

      it "returns fallback text when no assistant messages exist" do
        context = fake_context([])
        result = delegate.send(:extract_content, bad_res, context)
        expect(result).to eq("(sub-agent completed but produced no text response)")
      end

      it "skips assistant messages with empty content" do
        context = fake_context([
          FakeMessage.new(:assistant, "real answer"),
          FakeMessage.new(:assistant, ""),
        ])

        result = delegate.send(:extract_content, bad_res, context)
        expect(result).to eq("real answer")
      end

      it "skips assistant messages with non-string content" do
        context = fake_context([
          FakeMessage.new(:assistant, "text answer"),
          FakeMessage.new(:assistant, [{"type" => "tool_use"}]),
        ])

        result = delegate.send(:extract_content, bad_res, context)
        expect(result).to eq("text answer")
      end
    end

    context "when res.content returns nil (empty response)" do
      let(:nil_res) { Struct.new(:content).new(nil) }

      it "falls back to the last assistant text in context messages" do
        context = fake_context([
          FakeMessage.new(:assistant, "previous answer"),
        ])

        result = delegate.send(:extract_content, nil_res, context)
        expect(result).to eq("previous answer")
      end

      it "returns fallback text when no assistant messages exist" do
        context = fake_context([])
        result = delegate.send(:extract_content, nil_res, context)
        expect(result).to eq("(sub-agent completed but produced no text response)")
      end
    end

    context "when res.content returns empty string" do
      let(:empty_res) { Struct.new(:content).new("") }

      it "falls back to the last assistant text in context messages" do
        context = fake_context([
          FakeMessage.new(:assistant, "previous answer"),
        ])

        result = delegate.send(:extract_content, empty_res, context)
        expect(result).to eq("previous answer")
      end
    end
  end
end
