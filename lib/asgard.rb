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
  # Each file typically reopens class Tasks to add recipes.
  # The .loki entry point is excluded — it is loaded separately by run!.
  def self.load_loki(dir)
    Dir.glob(File.join(dir, "*.loki")).sort.each { |f| load f }
  end

  # Main entry point invoked by the asgard executable.
  def self.run!(argv)
    task_file = find_task_file or (warn "asgard: no .loki file found in #{Dir.pwd}"; exit 1)
    load_loki(File.dirname(task_file))
    load task_file
    Tasks.validate_deps!
    Tasks._reset_ran!
    Tasks.start(argv)
  rescue CircularDependencyError => e
    warn "asgard: circular dependency — #{e.message}"
    exit 1
  end
end
