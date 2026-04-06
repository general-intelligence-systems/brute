# frozen_string_literal: true

RSpec.describe Brute::Diff do
  describe ".unified" do
    it "generates a unified diff for changed content" do
      old = "line1\nold\nline3\n"
      new_text = "line1\nnew\nline3\n"
      diff = described_class.unified(old, new_text)
      expect(diff).to include("-old")
      expect(diff).to include("+new")
      expect(diff).to include("@@")
    end

    it "returns empty string for identical content" do
      text = "same\ncontent\n"
      expect(described_class.unified(text, text)).to eq("")
    end

    it "handles empty old content (new file)" do
      diff = described_class.unified("", "new\ncontent\n")
      expect(diff).to include("+new")
      expect(diff).to include("+content")
    end

    it "handles empty new content (deleted file)" do
      diff = described_class.unified("old\ncontent\n", "")
      expect(diff).to include("-old")
      expect(diff).to include("-content")
    end
  end
end
