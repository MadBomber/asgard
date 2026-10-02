# frozen_string_literal: true

require_relative "asgard/errors"
require_relative "asgard/version"
require_relative "asgard/kernel_methods"
require_relative "asgard/shell"
require_relative "asgard/base"
require_relative "asgard/tasks"
require_relative "asgard/doctor"

module Asgard
  # Search the current directory and its ancestors for a .loki task file.
  # Returns the path string, or nil if not found.
  def self.find_task_file
    loki_up
  end

  # `asgard schedule list` reports every project's scheduled entries, so it
  # works from a directory with no .loki above it.
  def self.machine_wide?(argv) = argv.first(2) == %w[schedule list]

  # Main entry point invoked by the asgard executable.
  def self.run!(argv)
    first = argv.first
    abort "asgard: unknown command '#{first}'" if first&.start_with?("_")
    if argv.include?("--version")
      puts Asgard::VERSION
      exit
    end
    if argv.include?("--doctor")
      Asgard::Doctor.new.run
      exit
    end
    task_file = find_task_file
    abort "asgard: no .loki file found in #{Dir.pwd}" unless task_file || machine_wide?(argv)
    before = Asgard::Base.subclasses.dup
    load task_file if task_file
    newly_defined = Asgard::Base.subclasses - before
    (newly_defined + [Tasks]).uniq.each(&:validate_deps!)
    Tasks._reset_ran!
    result = Tasks.start(argv)
    # Quality-gate convention: a task signals failure by returning :fail
    # (see dev/quality.loki's *_check tasks). Surface that as a nonzero
    # exit so callers (CI, cross-repo runners) can rely on $?.
    exit(1) if result == :fail
    result
  rescue CircularDependencyError => e
    abort "asgard: circular dependency — #{e.message}"
  rescue Error => e
    abort "asgard: #{e.message}"
  rescue Interrupt
    exit(130)
  end
end
