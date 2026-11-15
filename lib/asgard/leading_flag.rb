# frozen_string_literal: true

# Loaded alone by bin/asgard to answer --version before Thor loads, so it
# requires nothing.
module Asgard
  # Whether +flag+ is one of asgard's own options: among the options
  # before the first word that is not one (the task name). After it, the
  # word belongs to the task, which may take --version as an argument.
  def self.leading_flag?(argv, flag) = argv.take_while { |word| word.start_with?("-") }.include?(flag)

  # The options that set a global for whatever task runs, so they read the
  # same on either side of the task name.
  GLOBAL_FLAGS = %w[--debug --verbose].freeze

  # +argv+ with the task name first: leading GLOBAL_FLAGS move behind the
  # word they precede when the block says that word names a task. Thor
  # hands a command line that starts with an option to the default task,
  # so without this `asgard --verbose build` never reaches `build`.
  def self.task_first(argv)
    flags = argv.take_while { |word| GLOBAL_FLAGS.include?(word) }
    word  = argv[flags.size]
    return argv if flags.empty? || word.nil? || !yield(word)

    [word, *flags, *argv.drop(flags.size + 1)]
  end
end
