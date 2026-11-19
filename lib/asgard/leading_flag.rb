# frozen_string_literal: true

# Loaded alone by bin/asgard to answer --version before Thor loads, so it
# requires nothing.
module Asgard
  # Whether +flag+ is one of asgard's own options: among the options
  # before the first word that is not one (the task name). After it, the
  # word belongs to the task, which may take --version as an argument.
  def self.leading_flag?(argv, flag) = argv.take_while { |word| word.start_with?("-") }.include?(flag)

  # The options that set a global for whatever task runs, so they read the
  # same on either side of the task name: --debug and --verbose in every
  # form Thor accepts after it (--debug=VALUE, --no-debug, --skip-debug).
  GLOBAL_FLAG = /\A--(?:(?:debug|verbose)(?:=.*)?|(?:no|skip)-(?:debug|verbose))\z/

  def self.global_flag?(word) = GLOBAL_FLAG.match?(word)

  # +argv+ with the task name first: leading global flags move behind the
  # word they precede when the block says that word names a task. Thor
  # hands a command line that starts with an option to the default task,
  # so without this `asgard --verbose build` never reaches `build`.
  def self.task_first(argv)
    flags = argv.take_while { global_flag?(it) }
    word  = argv[flags.size]
    return argv if flags.empty? || word.nil? || !yield(word)

    [word, *flags, *argv.drop(flags.size + 1)]
  end
end
