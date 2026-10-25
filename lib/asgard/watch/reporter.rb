# frozen_string_literal: true

require "time"
require_relative "../pid"
require_relative "../state_dir"

module Asgard
  module Watch
    # The one writer of the watcher's log and per-entry state. Workers and
    # the dispatcher push frozen reports onto a shared queue; the reporter
    # drains it in a main-Ractor thread, appends a log line per report,
    # keeps the latest record per entry on disk through the state, and
    # tracks which pids are in flight so shutdown can say what it waits
    # for.
    class Reporter
      class << self
        # One log line for a report. behind: is the pid a trigger is queued
        # behind when its task is still running.
        def log_line(report, behind: nil)
          kind, entry, task, pid, at = report.values_at(:kind, :entry, :task, :pid, :at)
          head    = "#{Time.at(at).strftime('%Y-%m-%d %H:%M:%S')} #{kind} #{entry} task=#{task}"
          changed = paths(report)
          case kind
          when :trigger then "#{head} #{changed}#{" (queued behind pid #{behind})" if behind}"
          when :spawn   then "#{head} pid=#{pid} #{changed}"
          when :dropped then "#{head} #{changed} (dropped: the task's queue is full)"
          else               exit_line(head, report)
          end
        end

        def exit_line(head, report)
          line = "#{head} pid=#{report[:pid]} status=#{report[:status]} seconds=#{format('%.2f', report[:seconds])}"
          report[:error] ? "#{line} error=#{report[:error]}" : line
        end

        # The entry's record after this report: a spawn starts a new record
        # (no finished/status yet, which is how `list` shows "running"), an
        # exit completes the previous one.
        def entry_record(report, previous = nil)
          entry, task, pid, at = report.values_at(:entry, :task, :pid, :at)
          stamp = Time.at(at).iso8601
          return { entry:, task:, pid:, started: stamp, changes: report[:changes] } if report[:kind] == :spawn

          { entry:, task:, pid:, **previous.to_h, finished: stamp, status: report[:status], seconds: report[:seconds] }
        end

        # The changed paths of a trigger or spawn report, space-separated; "" for an exit.
        def paths(report) = report.fetch(:changes) { {} }.values.flatten.join(" ")

        # Whether a process exists; one we may not signal still exists.
        def alive?(pid) = Pid.alive?(pid)

        # The command line of a live process, or nil (see Asgard::Pid).
        def command_line(pid) = Pid.command_line(pid)

        # Whether pid is alive and is an asgard process whose command line
        # carries every word: ("watcher", "run") for a daemon, a task name
        # for a trigger. The current process always counts. A pidfile left
        # by a crash or a reboot can name a pid that an unrelated process
        # now holds, which a bare liveness check would call ours.
        def asgard_process?(pid, *words, command: nil) = Pid.matches?(pid, "asgard", *words, command:)
      end

      # state: responds to write_entry(name, record). max_log: is the size
      # past which the log is rotated (StateDir.rotate).
      def initialize(reports, log:, state:, max_log: StateDir.log_limit)
        @reports = reports
        @log     = log
        @max_log = max_log
        @state   = state
        @records = {}
        @running = {} # pid => task
        @mutex   = Mutex.new
      end

      # Handles reports until it pops nil.
      def run
        while (report = @reports.pop)
          handle(report)
        end
      end

      def start = Thread.new { run }

      # Tracks the report, then logs it. A report that cannot be written
      # (the state directory removed under a running daemon) is said so on
      # stderr; the reporter goes on, since every worker waits on it.
      def handle(report)
        kind    = report[:kind]
        trigger = kind == :trigger
        line    = Reporter.log_line(report, behind: trigger ? running_for(report[:task]) : nil)
        track(report) if %i[spawn exit].include?(kind)
        StateDir.rotate(@log, max_bytes: @max_log)
        File.open(@log, "a") { |file| file.puts(line) }
      rescue SystemCallError, IOError => e
        $stderr.puts "watcher: could not write #{kind} report for #{report[:entry]}: #{e.message}" # rubocop:disable Style/StderrPuts
      end

      # Pids of tasks in flight, ascending.
      def running = @mutex.synchronize { @running.keys.sort }

      # The in-flight pid of task, or nil.
      def running_for(task) = @mutex.synchronize { @running.key(task) }

      private

      def track(report)
        entry, pid = report.values_at(:entry, :pid)
        record = Reporter.entry_record(report, @records[entry])
        @records[entry] = record
        @state.write_entry(entry, record)
        @mutex.synchronize { record.key?(:finished) ? @running.delete(pid) : @running[pid] = record[:task] }
      end
    end
  end
end
