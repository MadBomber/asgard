# frozen_string_literal: true

require "fileutils"
require_relative "../state_dir"

module Asgard
  module Watch
    # Where one project's watcher keeps what outlives a daemon run: the
    # pidfile, the log, the declarations recorded at start, and one JSON
    # record per entry with its last run. Everything lives outside the
    # repository under $XDG_STATE_HOME/asgard/watch/<project-slug>/ (by
    # default ~/.local/state), with a file naming the project root so
    # `watcher list --all` can find every project without loading it.
    class State
      ROOT_FILE = StateDir::ROOT_FILE

      # Names the inherited descriptor of the held watcher.lock, from
      # `start` to the daemon it spawns and across a reload's exec.
      LOCK_ENV = "ASGARD_WATCH_LOCK_FD"

      # Names the file of changes a reloading daemon saw but did not run,
      # for the daemon its exec starts to run instead.
      PENDING_ENV = "ASGARD_WATCH_PENDING"

      attr_reader :dir, :root

      class << self
        def base_dir(home: Dir.home, env: ENV) = StateDir.base_dir("watch", home:, env:)

        # Every project with a state directory under base, as [slug, root] pairs.
        def all(base: base_dir) = StateDir.all(base:)

        # What `list` needs of a declaration, with the events Set as an Array.
        def declaration_record(spec) = spec.slice(:name, :task, :paths).merge(events: spec[:events].to_a)

        # Written whole then renamed, so a reader never sees a partial file.
        def write_json(path, value) = StateDir.write_json(path, value)

        def read_json(path) = StateDir.read_json(path)

        # The pending triggers a reload left at +path+ ([{ entry:, changes: }]),
        # removing the file so they run once; [] for no path or no file.
        def take_pending(path)
          return [] unless path

          pending = read_json(path) || []
          FileUtils.rm_f(path)
          pending
        end

        # Whether pid is a watcher daemon, not merely a live process.
        def daemon?(pid) = Reporter.asgard_process?(pid, "watcher", "run")

        # Whether an entry record describes a task still running: no exit
        # recorded and its pid still that task's asgard process. The
        # current process always counts, as for asgard_process?.
        def running?(entry)
          return false if entry.key?(:finished)

          pid = entry[:pid]
          pid == Process.pid || task_process?(entry[:task].to_s, command: Pid.command_line(pid))
        end

        # Whether +command+ (a command line, or nil for no process) runs
        # asgard with +task+ as a whole word: "t" is not "test_check".
        def task_process?(task, command:)
          words = command.to_s.split
          words.any? { |word| File.basename(word) == "asgard" } && words.include?(task)
        end
      end

      # base: is the directory every project's state lives under.
      def initialize(project:, root:, base: State.base_dir)
        @root = root
        @dir  = File.join(base, Schedule.slug(project))
      end

      def pid_path          = File.join(dir, "watcher.pid")
      def lock_path         = File.join(dir, "watcher.lock")
      def log_path          = File.join(dir, "watcher.log")
      def root_path         = File.join(dir, ROOT_FILE)
      def declarations_path = File.join(dir, "declarations.json")
      def pending_path      = File.join(dir, "pending.json")
      def entries_dir       = File.join(dir, "entries")
      def entry_path(name)  = File.join(entries_dir, "#{name}.json")

      # Creates the directories and records the root.
      def prepare
        StateDir.record_root(dir, root)
        FileUtils.mkdir_p(entries_dir)
        self
      end

      # One watcher per project: whoever holds an exclusive flock on
      # watcher.lock. The open File while held, nil when another process
      # holds it. The lock ends when the last descriptor of this open
      # closes, so a daemon that inherits it keeps it for its lifetime.
      # The descriptor is close-on-exec: only `start` and a reload hand it
      # on, by name (see LOCK_ENV); a task the daemon spawns, and anything
      # that task leaves running, never holds it.
      def acquire_lock
        FileUtils.mkdir_p(dir)
        file = File.open(lock_path, File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen -- held, not read
        file.close_on_exec = true
        return file if file.flock(File::LOCK_EX | File::LOCK_NB)

        file.close
        nil
      end

      # The lock a parent handed down (see LOCK_ENV), or nil when none was
      # or the descriptor is not this project's lock file. Handing it down
      # cleared close-on-exec, so it is set again here: otherwise every
      # task spawned would inherit the lock and could outlive the daemon
      # holding it.
      def adopt_lock(env = ENV)
        fd = Integer(env[LOCK_ENV].to_s, exception: false) or return nil
        io = File.for_fd(fd, autoclose: false)
        return nil unless File.exist?(lock_path) && File.identical?(io, lock_path) && io.flock(File::LOCK_EX | File::LOCK_NB)

        io.autoclose     = true
        io.close_on_exec = true
        io
      rescue Errno::EBADF, ArgumentError
        nil
      end

      # The inherited lock, else a fresh one; nil when another holds it.
      def lock(env = ENV) = adopt_lock(env) || acquire_lock

      def write_pid(pid) = File.write(pid_path, "#{pid}\n")

      def read_pid = File.exist?(pid_path) ? File.read(pid_path).to_i : nil

      # The daemon's pid when one is running, else nil. A pidfile left by a
      # crash counts as not running, even when another process has since
      # been given its pid.
      def running_pid
        pid = read_pid
        pid if pid&.positive? && State.daemon?(pid)
      end

      def clear = FileUtils.rm_f(pid_path)

      # The declarations of the running daemon (written by every `watcher
      # run`, a reload included), trimmed to what `list` shows.
      def write_declarations(specs)
        State.write_json(declarations_path, specs.map { |spec| State.declaration_record(spec) })
      end

      def read_declarations = State.read_json(declarations_path) || []

      def write_entry(name, record) = State.write_json(entry_path(name), record)

      def read_entry(name) = State.read_json(entry_path(name))

      # Every entry's latest record, keyed by entry name.
      # A corrupt record is left out (see StateDir.read_json).
      def entries
        Dir.glob(File.join(entries_dir, "*.json")).filter_map do |file|
          record = State.read_json(file)
          [File.basename(file, ".json"), record] if record
        end.to_h
      end

      # The records of tasks still running.
      def running_entries = entries.values.select { |entry| State.running?(entry) }
    end
  end
end
