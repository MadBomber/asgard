# frozen_string_literal: true

unless defined?(SimpleCov)
  require "simplecov"
  SimpleCov.start do
    skip "/test/"
    minimum_coverage 95
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "asgard"

# Schedule::Table requires tty-table lazily, and its unicode_utils prints
# Ruby warnings to $stderr on load. Loaded here, before parallel_runner
# forks, so no test's capture_io catches them.
require "tty-table"
require "tty-screen"

require "minitest/autorun"

require "open3"
require "fileutils"
require "tmpdir"

# Runs the real bin/asgard as its own process in a temp project whose
# .loki holds +loki+, for behaviour that only shows at the process level:
# exit statuses, what reaches stderr, a task that exits.
module AsgardProcess
  BIN = File.expand_path("../bin/asgard", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  # [stdout, stderr, Process::Status]
  def run_asgard(loki, *argv, files: {}, env: {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".loki"), loki)
      files.each do |name, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), body)
      end
      Open3.capture3(env, Gem.ruby, "-I", LIB, BIN, *argv, chdir: dir, stdin_data: "")
    end
  end
end
