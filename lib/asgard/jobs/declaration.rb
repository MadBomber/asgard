# frozen_string_literal: true

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

    # A task name may end in ? or !; its job name keeps to [\w-], which is
    # what a record's file name must be for `jobs list` to find it.
    def sequenced_name(task, sequence)
      raise ArgumentError, "sh background: true must be called from a task body" unless task

      :"#{task.to_s.gsub(/[^\w-]/, '_')}-#{sequence}"
    end

    def chosen_name(value)
      name = value.to_s.strip
      raise ArgumentError, "background: #{value.inspect} is not a job name (letters, digits and _ only)" unless name.match?(NAME)

      name.to_sym
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
    # [:exited, code] once the trampoline wrote a status, :gone when
    # neither (the trampoline died, or the machine rebooted).
    def status(exit_code:, verified:)
      return [:exited, exit_code] if exit_code
      return :running if verified

      :gone
    end

    # The STATUS column: "running", "exited 3 (2.5s)" or "gone".
    def describe_status(status, seconds: nil)
      return status.to_s unless status.is_a?(Array)

      duration = seconds ? " (#{format('%.1fs', seconds)})" : ""
      "exited #{status.last}#{duration}"
    end
  end
end
