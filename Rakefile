# frozen_string_literal: true

task :test do
  Dir["lib/**/*.rb"].each { |f| sh "bundle", "exec", "ruby", f }
end

task default: :test
