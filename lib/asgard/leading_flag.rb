# frozen_string_literal: true

# Loaded alone by bin/asgard to answer --version before Thor loads, so it
# requires nothing.
module Asgard
  # Whether +flag+ is one of asgard's own options: among the options
  # before the first word that is not one (the task name). After it, the
  # word belongs to the task, which may take --version as an argument.
  def self.leading_flag?(argv, flag) = argv.take_while { |word| word.start_with?("-") }.include?(flag)
end
