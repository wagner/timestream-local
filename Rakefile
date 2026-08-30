# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

desc "Build the container image"
task :build do
  sh "docker build -t timestream-local:dev ."
end

desc "Run the suite against a running container (docker-compose up -d first)"
task :test_container do
  sh({ "TIMESTREAM_LOCAL_ENDPOINT" => ENV.fetch("TIMESTREAM_LOCAL_ENDPOINT", "http://localhost:8080") },
     "bundle exec rake test")
end

task default: :test
