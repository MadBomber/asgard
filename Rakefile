# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

SIMPLECOV_PRELUDE = <<~RUBY
  require "simplecov"
  SimpleCov.start do
    add_filter "/test/"
    minimum_coverage 95
  end
RUBY

Minitest::TestTask.create do |t|
  t.test_prelude = SIMPLECOV_PRELUDE
end

task default: :test

RUBOCOP_ENV = { "RUBOCOP_CACHE_ROOT" => "tmp/rubocop_cache" }.freeze

desc "Check code style with RuboCop"
task :rubocop do
  sh RUBOCOP_ENV, "bundle exec rubocop"
end

desc "Auto-correct RuboCop offenses"
task :rubocop_fix do
  sh RUBOCOP_ENV, "bundle exec rubocop -a"
end

desc "Check code complexity with Flog (warn >=20, fail >=50)"
task :flog_check do
  require "flog"

  # Target to work toward; methods above this are warned but don't fail the gate.
  METHOD_WARN = 20.0
  # Current baseline floor — established from first run. Reduce incrementally.
  METHOD_FAIL = 50.0

  flogger = Flog.new(all: true)
  flogger.flog(*Dir.glob("lib/**/*.rb"))

  warnings = []
  failures = []

  flogger.each_by_score do |method, score|
    next if method.end_with?("#none")
    if score > METHOD_FAIL
      failures << "#{"%.1f" % score}: #{method}"
    elsif score > METHOD_WARN
      warnings << "#{"%.1f" % score}: #{method}"
    end
  end

  unless warnings.empty?
    puts "\nFlog warnings (#{METHOD_WARN}–#{METHOD_FAIL}) — target for future refactoring:"
    warnings.each { |v| puts "  #{v}" }
  end

  if failures.empty?
    puts "\nFlog: no methods exceed the failure threshold (>=#{METHOD_FAIL})"
  else
    puts "\nFlog failures (>=#{METHOD_FAIL}) — must be refactored:"
    failures.each { |v| puts "  #{v}" }
    $stdout.flush
    abort "\nFlog quality gate failed: #{failures.size} method(s) exceed #{METHOD_FAIL}"
  end
end

desc "Run all quality checks: tests (with coverage), RuboCop, and Flog"
task :quality do
  results = {}

  puts "\n#{"=" * 60}"
  puts "Quality Gate: Tests + Coverage"
  puts "=" * 60
  results[:tests] = system("bundle exec rake test") ? :pass : :fail

  puts "\n#{"=" * 60}"
  puts "Quality Gate: RuboCop"
  puts "=" * 60
  results[:rubocop] = system(RUBOCOP_ENV, "bundle exec rubocop") ? :pass : :fail

  puts "\n#{"=" * 60}"
  puts "Quality Gate: Flog Complexity"
  puts "=" * 60
  results[:flog] = system("bundle exec rake flog_check") ? :pass : :fail

  puts "\n#{"=" * 60}"
  puts "Quality Summary"
  puts "=" * 60
  results.each do |gate, status|
    icon = status == :pass ? "PASS" : "FAIL"
    puts "  [#{icon}] #{gate}"
  end
  puts "=" * 60

  abort "\nQuality gate failed" if results.values.any?(:fail)
  puts "\nAll quality gates passed."
end
