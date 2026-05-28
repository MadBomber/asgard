# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

SIMPLECOV_PRELUDE = <<~RUBY.freeze
  require "simplecov"
  SimpleCov.start do
    add_filter "/test/"
    minimum_coverage 95
  end
RUBY

Minitest::TestTask.create do |t|
  t.test_prelude = SIMPLECOV_PRELUDE
end

task quality: :test do
  sh "flog lib/"
end

task default: :test
