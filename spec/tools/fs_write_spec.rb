# frozen_string_literal: true

RSpec.describe Brute::Tools::FSWrite do
  around(:each) { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

  let(:tool) { described_class.new }

  it "writes content to a new file" do
    path = File.join(@dir, "new.rb")
    result = tool.call(file_path: path, content: "hello\n")
    expect(result[:success]).to be true
    expect(File.read(path)).to eq("hello\n")
  end

  it "returns a diff for new files" do
    path = File.join(@dir, "new.rb")
    result = tool.call(file_path: path, content: "line1\nline2\n")
    expect(result[:diff]).to include("+line1")
    expect(result[:diff]).to include("+line2")
  end

  it "returns a diff for overwritten files" do
    path = File.join(@dir, "existing.rb")
    File.write(path, "old content\n")
    result = tool.call(file_path: path, content: "new content\n")
    expect(result[:diff]).to include("-old content")
    expect(result[:diff]).to include("+new content")
  end

  it "creates parent directories" do
    path = File.join(@dir, "deep", "nested", "file.rb")
    result = tool.call(file_path: path, content: "nested\n")
    expect(result[:success]).to be true
    expect(File.exist?(path)).to be true
  end

  it "returns byte count" do
    path = File.join(@dir, "test.rb")
    result = tool.call(file_path: path, content: "hello")
    expect(result[:bytes]).to eq(5)
  end
end
