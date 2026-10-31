# frozen_string_literal: true

require "time"

module Asgard
  # Background jobs: a process a task starts on purpose, by name, that
  # outlives asgard and that a later `asgard jobs` can list and stop.
  # `sh "mkdocs serve", background: true` starts one; see
  # Jobs::Launcher for how, Jobs::State for what is kept on disk and
  # Jobs::Commands for the management commands. This file holds the pure
  # rules: naming, records, name resolution and status.
  module Jobs
    # A job name a user may choose: letters, digits and underscore, so it
    # is safe as a file name and can never look like an auto-generated
    # "<task>-<N>" name.
    NAME = /\A\w+\z/

    # One started job, as `sh ..., background:` returns it.
    Job = Data.define(:name, :task, :pid, :log)

    module_function

    # The job name a `background:` value asks for, or nil for the
    # foreground. +task+ is the task whose body made the call and
    # +sequence+ its next job number, consulted only for `true`: a named
    # job never consumes a number, so adding or removing one never
    # renumbers the rest.
    def job_name(background, task:, sequence: nil)
      case background
      when nil, false   then nil
      when true         then sequenced_name(task, sequence)
      when Symbol, String then chosen_name(background)
      else raise ArgumentError, "background: must be true, a Symbol or a String, not #{background.inspect}"
      end
    end

    # How a task name's characters outside \w are spelled in its job name,
    # which keeps to [\w-] because a record's file name must for `jobs
    # list` to find it. Every spelling starts with "-" and none with
    # "-<digit>", so no two task names share a job name and none reads as
    # the "-<N>" counter: ready? is ready-q-1, never the ready_-1 of ready_.
    NAME_ESCAPES = { "?" => "-q", "!" => "-b", "=" => "-e", "-" => "--" }.freeze

    def sequenced_name(task, sequence)
      raise ArgumentError, "sh background: true must be called from a task body" unless task

      :"#{escape_task(task)}-#{sequence}"
    end

    # Any other character (a non-ASCII letter) is "-u" and six hex digits.
    def escape_task(task) = task.to_s.gsub(/\W/) { |char| NAME_ESCAPES.fetch(char) { format("-u%06x", char.ord) } }

    def chosen_name(value)
      name = value.to_s.strip
      raise ArgumentError, "background: #{value.inspect} is not a job name (letters, digits and _ only)" unless name.match?(NAME)

      name.to_sym
    end

    # Whether +record+ is one a started job wrote: a Hash with a name, a
    # pid and a group id above 1 (kill(2) reads -1 and 0 as "everyone"
    # and "us"), a script path to verify against and a start time. A hand
    # edit or another tool's JSON fails this and stays out of listings.
    def valid_record?(record)
      return false unless record.is_a?(Hash)

      name, pid, pgid, script, started = record.values_at(:name, :pid, :pgid, :script, :started)
      text?(name) && text?(script) && process_id?(pid) && process_id?(pgid) && time?(started)
    end

    def text?(value) = value.is_a?(String) && !value.empty?

    def process_id?(id) = id.is_a?(Integer) && id > 1

    def time?(value)
      value.is_a?(String) && Time.iso8601(value).is_a?(Time)
    rescue ArgumentError
      false
    end

    # The first non-blank line of a script, for the listing.
    def summary(script) = script.to_s.each_line.map(&:strip).find { |line| !line.empty? }.to_s

    # The record written to disk for a started job.
    def record(name:, task:, pid:, pgid:, cwd:, script:, log:, command:, started:)
      { name: name.to_s, task: task.to_s, pid:, pgid:, started:, cwd:, script:, log:, command: }
    end

    # +task+ plus every task reachable through +deps+ (a `_deps` Hash of
    # stage lists), in discovery order. `stop servers` reaches the `db-1`
    # a dependency started.
    def closure(task, deps)
      seen  = []
      queue = [task.to_sym]
      until queue.empty?
        current = queue.shift
        next if seen.include?(current)

        seen << current
        queue.concat(Array(deps[current]).flatten.map(&:to_sym))
      end
      seen
    end

    # The records +names+ pick out: an exact job name first, else every
    # record whose task is the name or, through +closure+ (a callable from
    # task name to task names), one it depends on. Returns [records,
    # unknown names].
    def resolve(names, records, closure: nil)
      found   = []
      unknown = []
      names.each do |name|
        matches = matching_records(name.to_s, records, closure)
        matches.empty? ? unknown << name.to_s : found.concat(matches)
      end
      [found.uniq, unknown]
    end

    def matching_records(name, records, closure)
      exact = records.select { |record| record[:name].to_s == name }
      return exact unless exact.empty?

      tasks = (closure ? closure.call(name) : [name]).map(&:to_s)
      records.select { |record| tasks.include?(record[:task].to_s) }
    end

    # What a record's job is doing now: :running while its pid verifies,
    # [:exited, code] once the trampoline wrote a status (with
    # :processes_left while processes the script started remain in its
    # group), :gone when neither (the trampoline died, or the machine
    # rebooted).
    def status(exit_code:, verified:, leftovers: false)
      return [:exited, exit_code, (:processes_left if leftovers)].compact if exit_code
      return :running if verified

      :gone
    end

    # The STATUS column: "running", "exited 3 (2.5s)", "exited 0 (2.5s,
    # processes left)" or "gone".
    def describe_status(status, seconds: nil)
      return status.to_s unless status.is_a?(Array)

      _, code, left = status
      notes = [(format("%.1fs", seconds) if seconds), ("processes left" if left)].compact
      notes.empty? ? "exited #{code}" : "exited #{code} (#{notes.join(', ')})"
    end
  end
end
