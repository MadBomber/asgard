# frozen_string_literal: true

require_relative "asgard/version"
require_relative "asgard/shell"
require_relative "asgard/base"
require_relative "asgard/tasks"

module Asgard
  class Error < StandardError; end
  class CircularDependencyError < Error; end

  # Search the current directory and its ancestors for a .loki task file.
  # Returns the path string, or nil if not found.
  def self.find_task_file
    dir = Dir.pwd
    loop do
      candidate = File.join(dir, ".loki")
      return candidate if File.exist?(candidate)
      parent = File.dirname(dir)
      break if parent == dir
      dir = parent
    end
    nil
  end

  # Load all *.loki files from dir in alphabetical order.
  # Each file typically reopens class Tasks to add tasks.
  # The .loki entry point is excluded — it is loaded separately by run!.
  def self.load_loki(dir)
    Dir.glob(File.join(dir, "*.loki")).each { |f| load f }
  end

  # Main entry point invoked by the asgard executable.
  def self.run!(argv)
    auto_load = argv.delete("--auto-load")
    abort "asgard: unknown command '#{argv.first}'" if argv.first&.start_with?("_")
    task_file = find_task_file or abort "asgard: no .loki file found in #{Dir.pwd}"
    before = Asgard::Base.subclasses.dup
    load_loki(File.dirname(task_file)) if auto_load
    load task_file
    newly_defined = Asgard::Base.subclasses - before
    (newly_defined + [Tasks]).uniq.each(&:validate_deps!)
    Tasks._reset_ran!
    Tasks.start(argv)
  rescue CircularDependencyError => e
    abort "asgard: circular dependency — #{e.message}"
  rescue Error => e
    abort "asgard: #{e.message}"
  end
end
