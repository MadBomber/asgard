# frozen_string_literal: true

require_relative "asgard/version"
require_relative "asgard/shell"
require_relative "asgard/base"

module Asgard
  class Error < StandardError; end
  class CircularDependencyError < Error; end

  # Search the current directory and its ancestors for task files.
  # Returns an array of paths, or nil if nothing is found.
  #
  # Priority:
  #   1. A single .loki file in the directory (default/hidden task file)
  #   2. All *.loki files in the directory, sorted alphabetically
  def self.find_task_files
    dir = Dir.pwd
    loop do
      dot_loki = File.join(dir, ".loki")
      return [dot_loki] if File.exist?(dot_loki)

      matches = Dir.glob(File.join(dir, "*.loki")).sort
      return matches unless matches.empty?

      parent = File.dirname(dir)
      break if parent == dir
      dir = parent
    end
    nil
  end
end
