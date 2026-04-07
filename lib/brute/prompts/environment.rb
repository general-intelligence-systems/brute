# frozen_string_literal: true

module Brute
  module Prompts
    module Environment
      def self.call(ctx)
        cwd = ctx[:cwd] || Dir.pwd
        model = ctx[:model_name].to_s
        git = File.exist?(File.join(cwd, ".git"))

        parts = []
        parts << "You are powered by the model named #{model}." unless model.empty?
        parts << ""
        parts << "Here is some useful information about the environment you are running in:"
        parts << "<env>"
        parts << "  Working directory: #{cwd}"
        parts << "  Is directory a git repo: #{git ? "yes" : "no"}"
        parts << "  Platform: #{RUBY_PLATFORM}"
        parts << "  Today's date: #{Time.now.strftime("%a %b %d %Y")}"
        parts << "</env>"
        parts.join("\n")
      end
    end
  end
end
