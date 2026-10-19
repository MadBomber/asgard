# frozen_string_literal: true

require "time"

module Asgard
  module Watch
    # The one writer of the watcher's log and per-entry state. Workers and
    # the dispatcher push frozen reports onto a shared queue; the reporter
    # drains it in a main-Ractor thread, appends a log line per report,
    # keeps the latest record per entry on disk through the state, and
    # tracks which pids are in flight so shutdown can wait for them.
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
          else               "#{head} pid=#{pid} status=#{report[:status]} seconds=#{format('%.2f', report[:seconds])}"
          end
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
        def alive?(pid)
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          true
        end
      end

      # state: responds to write_entry(name, record).
      def initialize(reports, log:, state:)
        @reports = reports
        @log     = log
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

      def handle(report)
        trigger = report[:kind] == :trigger
        line    = Reporter.log_line(report, behind: trigger ? running_for(report[:task]) : nil)
        File.open(@log, "a") { |file| file.puts(line) }
        track(report) unless trigger
      end

      # Pids of tasks in flight, ascending.
      def running = @mutex.synchronize { @running.keys.sort }

      # The in-flight pid of task, or nil.
      def running_for(task) = @mutex.synchronize { @running.key(task) }

      # Blocks until no task is in flight, saying what it waits for once
      # per interval. A pid that is gone without an exit report (a worker
      # died between its reports) is forgotten rather than waited on.
      def drain(interval: 1.0, out: $stdout)
        until (pids = running).empty?
          out.puts "watcher: waiting for pid #{pids.join(', ')}"
          sleep interval
          forget_dead
        end
      end

      private

      def track(report)
        entry, pid = report.values_at(:entry, :pid)
        record = Reporter.entry_record(report, @records[entry])
        @records[entry] = record
        @state.write_entry(entry, record)
        @mutex.synchronize { record.key?(:finished) ? @running.delete(pid) : @running[pid] = record[:task] }
      end

      def forget_dead
        @mutex.synchronize { @running.delete_if { |pid, _task| !Reporter.alive?(pid) } }
      end
    end
  end
end
