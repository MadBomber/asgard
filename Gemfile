# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in asgard.gemspec
gemspec

# Everything below is for working on asgard itself; users get only what the
# gemspec declares.
group :development, :test do
  gem "irb"                  # Interactive Ruby command-line tool for REPL (Read Eval Print Loop).
  gem "minitest", "~> 5.16"  # minitest provides a complete suite of testing facilities supporting TDD, BDD, mocking, and benchmarking
  gem "rake", "~> 13.0"      # Rake is a Make-like program implemented in Ruby
  gem "simplecov", "~> 0.22" # Code coverage for Ruby

  # Quality gate (asgard quality)
  gem "archspec"       # Architecture linter for Ruby and Rails.
  gem "bundler-audit"  # Patch-level verification for Bundler
  gem "exhale"         # The contraction gate for Rails: no PR merges while the codebase holds duplication the Contract doesn't keep
  gem "fasterer"       # Run Ruby more than fast. Fasterer
  gem "flay"           # Flay analyzes code for structural similarities
  gem "flog"           # Flog reports the most tortured code in an easy to read pain report
  gem "reek"           # Code smell detector for Ruby
  gem "rubocop"        # Automatic Ruby code style checking tool.
end
