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
        # one that is now asgard itself, and so does a record that is not
        # a job's (Jobs.valid_record?). A ps that cannot tell raises
        # Pid::Unusable rather than calling every job gone.
        def verified?(record)
          return false unless Jobs.valid_record?(record)

          Pid.require_ps!
          Pid.matches?(record[:pid], record[:script], self_ok: false) || survives?(record)
        end

        # Whether the job outlived its trampoline: some process in its group
        # still runs the script. A group id is never reused while the group
        # has members, so a match is still the job we started.
        def survives?(record, ps: Pid.method(:group_command_lines))
          pgid   = record[:pgid]
          script = record[:script].to_s
          return false unless job_group?(pgid) && !script.empty?

          ps.call(pgid).any? { |command| command.include?(script) }
        end

        # Whether +pgid+ could be a job's group at all: a group id above 1
        # that is not asgard's own. Nothing else is ever looked up or
        # signalled.
        def job_group?(pgid) = Jobs.process_id?(pgid) && pgid != Process.getpgrp

        # Whether the job still owns processes: it is running, or its
        # script exited and left processes in its group (`sleep 60 &`).
        # Those are what `stop` signals and why `clean` keeps the record.
        def active?(record) = verified?(record) || (Jobs.valid_record?(record) && leftovers?(record, exited_at: exited_at(record)))

        # Whether group +pgid+ still holds a process that started before
        # the trampoline exited at +exited_at+. The id cannot be reused
        # while the group has members, but once they are gone a later
        # group may take it, and every member of such a group is younger
        # than our exit; one second of slack covers ps's resolution.
        def leftovers?(record, exited_at:, ps: Pid.method(:group_processes))
          pgid = record[:pgid]
          return false unless exited_at && job_group?(pgid)

          ps.call(pgid).any? { |member| member.started <= exited_at + 1 }
        end

        # The status file of a record's job, beside its script.
        def status_file(record) = File.join(File.dirname(record[:script]), "#{record[:name]}.status")

        # When the trampoline wrote the job's status, or nil.
        def exited_at(record) = mtime_of(status_file(record))

        # When +path+ was last written, or nil when it does not exist.
        def mtime_of(path) = File.exist?(path) ? File.mtime(path) : nil

        # Writes 137 (128 + KILL) as the job's status unless one is
        # written: a group KILL takes the trampoline with it, so nothing
        # else records how the job ended. A record that is not a job's
        # writes nothing.
        def record_kill(record)
          return unless Jobs.valid_record?(record)

          File.open(status_file(record), "wx", 0o600) { |file| file.puts(128 + 9) }
        rescue Errno::EEXIST, Errno::ENOENT
          nil
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

      # The record for +name+, or nil when there is none or it is not a
      # job's record (Jobs.valid_record?).
      def read_record(name) = StateDir.read_json(record_path(name)).then { Jobs.valid_record?(it) ? it : nil }

      # Every job's record, oldest start first. Only "<name>.json" counts,
      # never the dot-prefixed tempfile write_json is still filling, and a
      # file that is not a job's record is left out (see invalid_records).
      def records
        record_files.filter_map { |path| StateDir.read_json(path) }.select { |record| Jobs.valid_record?(record) }
                    .sort_by { |record| [record[:started], record[:name]] }
      end

      # The record files that are not a job's record: unparsable JSON, a
      # hand edit, another tool's file.
      def invalid_records = record_files.reject { |path| Jobs.valid_record?(StateDir.read_json(path)) }

      def record_files
        Dir.children(dir).grep(RECORD).sort.map { |file| File.join(dir, file) }
      rescue Errno::ENOENT
        []
      end

      def verified?(record) = State.verified?(record)

      def active?(record) = State.active?(record)

      # Forgets +name+ (record, script, status and log) unless its job
      # still owns processes; true when it did. Holds the start lock and
      # reads the record again inside it, so a start that ran meanwhile
      # keeps the fresh record it wrote. A record that is not a job's is
      # forgotten too: it cannot be running.
      def forget_unless_active(name)
        with_lock(name) do
          next false unless File.exist?(record_path(name))

          record = read_record(name)
          next false if record && active?(record)

          remove(name, keep_log: false)
          true
        end
      end

      # The exit code the trampoline wrote, or nil while none is written.
      def exit_code(name)
        path = status_path(name)
        Integer(File.read(path).strip, exception: false) if File.exist?(path)
      end

      # When the status was written, or nil.
      def exit_time(name) = State.mtime_of(status_path(name))

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
