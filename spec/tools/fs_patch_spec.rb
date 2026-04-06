# frozen_string_literal: true

RSpec.describe Brute::Tools::FSPatch do
  around(:each) { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

  let(:tool) { described_class.new }

  it "replaces old_string with new_string" do
    path = File.join(@dir, "test.rb")
    File.write(path, "hello world\n")
    result = tool.call(file_path: path, old_string: "world", new_string: "ruby")
    expect(result[:success]).to be true
    expect(File.read(path)).to eq("hello ruby\n")
  end

  it "returns a unified diff" do
    path = File.join(@dir, "test.rb")
    File.write(path, "line1\nold line\nline3\n")
    result = tool.call(file_path: path, old_string: "old line", new_string: "new line")
    expect(result[:diff]).to include("-old line")
    expect(result[:diff]).to include("+new line")
  end

  it "raises when file not found" do
    expect {
      tool.call(file_path: File.join(@dir, "nope.rb"), old_string: "a", new_string: "b")
    }.to raise_error(/File not found/)
  end

  it "raises when old_string not found" do
    path = File.join(@dir, "test.rb")
    File.write(path, "hello\n")
    expect {
      tool.call(file_path: path, old_string: "missing", new_string: "new")
    }.to raise_error(/old_string not found/)
  end

  it "supports replace_all" do
    path = File.join(@dir, "test.rb")
    File.write(path, "aaa bbb aaa\n")
    result = tool.call(file_path: path, old_string: "aaa", new_string: "ccc", replace_all: true)
    expect(result[:replacements]).to eq(2)
    expect(File.read(path)).to eq("ccc bbb ccc\n")
  end
end
