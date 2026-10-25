# frozen_string_literal: true

require "fileutils"
require_relative "../pid"
require_relative "../state_dir"

module Asgard
  module Jobs
    # Where one project's jobs keep what outlives the asgard run that
    # started them, under $XDG_STATE_HOME/asgard/jobs/<project-slug>/:
    # per job name a JSON record, the script as handed to the shell, the
    # log, and the exit status the trampoline writes when the job ends.
    # Everything stays until the next start of that name or `jobs clean`,
    # so the log of a crashed job can still be read.
    class State
      # A job's record: a chosen name (\w+) or a sequenced "<task>-<N>".
      # Dotfiles never match, which is how a half-written tempfile stays out.
      RECORD = /\A[\w-]+\.json\z/

      attr_reader :dir, :root

      class << self
        def base_dir(home: Dir.home, env: ENV) = StateDir.base_dir("jobs", home:, env:)

        # Every project with job state under base, as [slug, root] pairs.
        def all(base: base_dir) = StateDir.all(base:)

        # Whether a record's job is still the process we started: its pid
        # is alive and runs the trampoline whose command line carries the
        # script path. A reused pid after a reboot fails this, and so does
        # one that is now asgard itself.
        def verified?(record) = Pid.matches?(record[:pid], record[:script].to_s, self_ok: false) || survives?(record)

        # Whether the job outlived its trampoline: some process in its group
        # still runs the script. A group id is never reused while the group
        # has members, so a match is still the job we started.
        def survives?(record, ps: Pid.method(:group_command_lines))
          pgid   = record[:pgid]
          script = record[:script].to_s
          return false unless pgid.is_a?(Integer) && pgid > 1 && pgid != Process.getpgrp && !script.empty?

          ps.call(pgid).any? { |command| command.include?(script) }
        end
      end

      def initialize(project:, root:, base: State.base_dir)
        @root = root
        @dir  = File.join(base, Schedule.slug(project))
      end

      def record_path(name)      = File.join(dir, "#{name}.json")
      def script_path(name, ext) = File.join(dir, "#{name}#{ext}")
      def log_path(name)         = File.join(dir, "#{name}.log")
      def status_path(name)      = File.join(dir, "#{name}.status")
      def lock_path(name)        = File.join(dir, ".#{name}.lock")

      # Runs the block holding an exclusive flock for +name+, so two starts
      # of one name (two terminals, two parallel dependencies) take turns:
      # the second sees the first's record and finds the job running. The
      # lock file is a dotfile, so RECORD and `remove` never see it.
      def with_lock(name)
        FileUtils.mkdir_p(dir)
        File.open(lock_path(name), File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          yield
        end
      end

      # Creates the directory and records the root.
      def prepare
        StateDir.record_root(dir, root)
        self
      end

      def write_record(record) = StateDir.write_json(record_path(record[:name]), record)

      def read_record(name) = StateDir.read_json(record_path(name))

      # Every job's record, oldest start first. Only "<name>.json" counts,
      # never the dot-prefixed tempfile write_json is still filling.
      def records
        Dir.children(dir).grep(RECORD).filter_map { |file| StateDir.read_json(File.join(dir, file)) }
           .sort_by { |record| [record[:started].to_s, record[:name].to_s] }
      rescue Errno::ENOENT
        []
      end

      def verified?(record) = State.verified?(record)

      # The exit code the trampoline wrote, or nil while none is written.
      def exit_code(name)
        path = status_path(name)
        Integer(File.read(path).strip, exception: false) if File.exist?(path)
      end

      # When the status was written, or nil.
      def exit_time(name) = File.exist?(status_path(name)) ? File.mtime(status_path(name)) : nil

      # Forgets a job: its record, script and status go; the log is kept
      # but emptied, so a restart appends to a fresh file, unless
      # keep_log: false deletes it too (`jobs clean`).
      def remove(name, keep_log: true)
        log   = log_path(name)
        files = Dir.exist?(dir) ? Dir.children(dir).select { |file| file.start_with?("#{name}.") }.map { |file| File.join(dir, file) } : []
        FileUtils.rm_f(keep_log ? files - [log] : files)
        File.truncate(log, 0) if keep_log && File.exist?(log)
      end
    end
  end
end
