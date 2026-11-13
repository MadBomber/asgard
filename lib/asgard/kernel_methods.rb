# frozen_string_literal: true

# Every helper defined here is also in Asgard::Base::KERNEL_HELPERS, so a
# task or helper by its name is refused rather than hiding it.
module Kernel
  def debug?   = $DEBUG
  def verbose? = $VERBOSE
  module_function :debug?, :verbose?

  # Fetch an environment variable by symbol or string name.
  # The name is converted to an uppercase string automatically.
  # Raises KeyError when the variable is missing and no default is given.
  def env(name, default = nil)
    key = name.to_s.upcase
    default.nil? ? ENV.fetch(key) : ENV.fetch(key, default)
  end
  module_function :env

  # The files the watcher saw change when it triggered this task, as an
  # Asgard::Changes (modified, added, removed, all). Every list is empty
  # when the task is run by hand.
  def changes = Asgard::Changes.current
  module_function :changes

  # The nearest +name+ in the current directory or an ancestor, as a
  # Pathname, or nil. A directory by that name is not it.
  def loki_up(name = ".loki")
    Pathname.new(Dir.pwd).ascend.map { it + name }.find(&:file?)
  end
  module_function :loki_up

  # +from+ is the call-site location used to resolve a relative +path+. It
  # defaults to the immediate caller, but is exposed as a keyword so a
  # wrapper (e.g. Asgard::Doctor's import tracer, prepended via `super`)
  # can thread through the *real* caller instead of its own frame.
  #
  # Only +path+ as written decides whether it is a glob. The caller's
  # directory is the glob's base, never part of the pattern, so a project
  # directory named like a glob ("glob[1]") does not change what matches.
  def import(path, from: caller_locations(1, 1).first)
    path = path.to_s
    raise ArgumentError, "import: path must end with .loki (got #{path.inspect})" unless path.end_with?(".loki")
    base   = File.dirname(from.absolute_path) unless File.absolute_path?(path)
    paths  = Asgard.glob?(path) ? Dir.glob(path, base:) : [path]
    loaded = paths.map { File.expand_path(it, base) }.map do |p|
      if $LOADED_FEATURES.include?(p)
        warn "import: skip #{p} (already loaded)" if debug?
        next false
      end
      warn "import: #{p}" if verbose? || debug?
      # Recorded before it loads, as Asgard.load_root does, so two files
      # that import each other each load once instead of without end.
      $LOADED_FEATURES << p
      load p
      true
    end
    loaded.any?
  end
  module_function :import

  # The paths found are handed to import escaped: the directory they sit
  # in is part of a path, not a pattern.
  def import_up(name = ".loki")
    if Asgard.glob?(name)
      Pathname.new(Dir.pwd).ascend do |dir|
        matches = Dir.glob(name, base: dir)
        next if matches.empty?

        warn "import_up: #{name} → #{dir}" if verbose? || debug?
        return matches.map { |p| import(Asgard.glob_escape(File.join(dir, p))) }.any?
      end
      warn "import_up: #{name} not found" if debug?
      return false
    end
    path = loki_up(name)
    unless path
      warn "import_up: #{name} not found" if debug?
      return false
    end
    warn "import_up: #{name} → #{path}" if verbose? || debug?
    import Asgard.glob_escape(path)
  end
  module_function :import_up
end
