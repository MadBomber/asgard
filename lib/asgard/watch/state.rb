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

        # Whether pid is a watcher daemon, not merely a live process.
        def daemon?(pid) = Reporter.asgard_process?(pid, "watcher", "run")

        # Whether an entry record describes a task still running: no exit
        # recorded and its pid still that task's asgard process.
        def running?(entry) = !entry.key?(:finished) && Reporter.asgard_process?(entry[:pid], entry[:task].to_s)
      end

      # base: is the directory every project's state lives under.
      def initialize(project:, root:, base: State.base_dir)
        @root = root
        @dir  = File.join(base, Schedule.slug(project))
      end

      def pid_path          = File.join(dir, "watcher.pid")
      def log_path          = File.join(dir, "watcher.log")
      def root_path         = File.join(dir, ROOT_FILE)
      def declarations_path = File.join(dir, "declarations.json")
      def entries_dir       = File.join(dir, "entries")
      def entry_path(name)  = File.join(entries_dir, "#{name}.json")

      # Creates the directories and records the root.
      def prepare
        StateDir.record_root(dir, root)
        FileUtils.mkdir_p(entries_dir)
        self
      end

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

      # The declarations at start time, trimmed to what `list` shows.
      def write_declarations(specs)
        State.write_json(declarations_path, specs.map { |spec| State.declaration_record(spec) })
      end

      def read_declarations = State.read_json(declarations_path) || []

      def write_entry(name, record) = State.write_json(entry_path(name), record)

      def read_entry(name) = State.read_json(entry_path(name))

      # Every entry's latest record, keyed by entry name.
      def entries = Dir.glob(File.join(entries_dir, "*.json")).to_h { |file| [File.basename(file, ".json"), State.read_json(file)] }

      # The records of tasks still running.
      def running_entries = entries.values.select { |entry| State.running?(entry) }
    end
  end
end
