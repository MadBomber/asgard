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

  # The directory of the nearest .loki, or the current directory without
  # one: where the watcher and background jobs file their state. Fixed
  # for the length of a run! (see pin_project_root), so a task that
  # changes directory first still files its jobs under this project.
  def self.project_root = @project_root || File.realpath((find_task_file&.dirname || Dir.pwd).to_s)

  def self.pin_project_root(root) = @project_root = root

  # `asgard schedule list`, `asgard watcher list` and `asgard jobs list`
  # report every project's entries, so they work from a directory with no
  # .loki above it.
  def self.machine_wide?(argv) = [%w[schedule list], %w[watcher list], %w[jobs list], %w[jobs]].include?(argv.first(2))

  # The root .loki is loaded directly rather than through `import`, so
  # record it the way import would. Otherwise an `import_up` in a child
  # file finds the root, reloads it, and the two import each other without
  # end.
  def self.load_root(path)
    path = File.expand_path(path.to_s)
    $LOADED_FEATURES << path unless $LOADED_FEATURES.include?(path)
    load path
  end

  # A frame of the backtrace inside a task file: "/proj/.loki:12" from
  # "/proj/.loki:12:in '<class:Tasks>'".
  LOKI_FRAME = /\A(.*?\.loki:\d+)/

  # One line for an error raised while the task files load: the nearest
  # .loki location, the message's first line and the class. A SyntaxError
  # names its own location in its message, so that is used as is.
  def self.load_error_message(error)
    first = error.message.lines.first.to_s.strip
    return "#{first} (#{error.class})" if error.is_a?(SyntaxError) && first.match?(LOKI_FRAME)

    where = Array(error.backtrace).lazy.filter_map { |frame| frame[LOKI_FRAME, 1] }.first
    [where, "#{first} (#{error.class})"].compact.join(": ")
  end

  # Loads the task files; anything they raise ends asgard with one line
  # (see load_error_message), or the full backtrace with ASGARD_TRACE set.
  def self.load_tasks(task_file)
    load_root(task_file) if task_file
  rescue Error
    raise
  rescue ScriptError, StandardError => e
    raise if ENV["ASGARD_TRACE"]

    abort "asgard: #{load_error_message(e)}"
  end

  # Whether +flag+ is one of asgard's own options: among the options
  # before the first word that is not one (the task name). After it, the
  # word belongs to the task, which may take --version as an argument.
  def self.leading_flag?(argv, flag) = argv.take_while { |word| word.start_with?("-") }.include?(flag)

  # --version and --doctor answer and exit before any task file loads.
  def self.answer_flags(argv)
    first = argv.first
    abort "asgard: unknown command '#{first}'" if first&.start_with?("_")
    if leading_flag?(argv, "--version")
      puts Asgard::VERSION
      exit
    end
    return unless leading_flag?(argv, "--doctor")

    Asgard::Doctor.new.run
    exit
  end

  # Finds and loads the task files and checks every class they defined.
  def self.boot(argv)
    task_file = find_task_file
    abort "asgard: no .loki file found in #{Dir.pwd}" unless task_file || machine_wide?(argv)
    before = Asgard::Base._asgard_subclasses.dup
    load_tasks(task_file)
    ((Asgard::Base._asgard_subclasses - before) + [Tasks]).uniq.each(&:validate_deps!)
  end

  # Main entry point invoked by the asgard executable.
  def self.run!(argv)
    answer_flags(argv)
    boot(argv)
    Tasks._reset_ran!
    pin_project_root(project_root)
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
  ensure
    pin_project_root(nil)
  end
end
