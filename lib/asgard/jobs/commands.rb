# frozen_string_literal: true

require "time"

# warn is silent when $VERBOSE is nil and bypasses $stderr in Ruby 4.0 (see
# base/task_dsl.rb); these messages are for the user, so they always print.
# rubocop:disable Style/StderrPuts

module Asgard
  module Jobs
    # `asgard jobs SUBCOMMAND` — lists, stops and restarts the background
    # jobs that `sh ..., background:` started. Subclasses Asgard::Base
    # rather than Tasks so `asgard jobs help` lists only these
    # subcommands, not every project task.
    class Commands < Asgard::Base
      namespace "jobs"
      default_command :list

      HEADERS  = %w[JOB TASK PID STATUS STARTED COMMAND].freeze
      KEYS     = %i[name task pid state started command].freeze
      FLEXIBLE = [5].freeze

      class << self
        # One `list` row per record, with what the job is doing now.
        def rows(state) = state.records.map { |record| row(record, state) }

        def row(record, state)
          name    = record[:name]
          exited  = state.exit_time(name)
          status  = Jobs.status(exit_code: state.exit_code(name), verified: state.verified?(record),
                                leftovers: State.leftovers?(record, exited_at: exited))
          seconds = (exited - Time.iso8601(record[:started])).round(1) if status.is_a?(Array)
          { name:, task: record[:task], pid: record[:pid], state: Jobs.describe_status(status, seconds:),
            started: Time.iso8601(record[:started]).strftime("%Y-%m-%d %H:%M:%S"), command: record[:command] }
        end

        # One line per record file +states+ left out of the listing.
        def skipped_lines(states) = states.flat_map(&:invalid_records).map { |path| "jobs: skipped #{path}: not a job record" }

        # The argv that follows a log the way `tail -f` does, from the top.
        def tail_argv(path) = ["tail", "-n", "+1", "-f", path]
      end

      desc "tree", "Print a tree of the jobs subcommands", hide: true
      # Redefined only to re-register tree as hidden in this namespace.
      def tree = super # rubocop:disable Lint/UselessMethodDefinition

      no_commands do
        def jobs_root = @jobs_root ||= Asgard.project_root

        def jobs_project = @jobs_project ||= Schedule.project_slug(jobs_root)

        def state = @state ||= State.new(project: jobs_project, root: jobs_root)

        # True when a command should cover every project: asked for with
        # --all, or there is no .loki here, so no single project to scope to.
        def every_project? = options[:all] || Asgard.find_task_file.nil?

        # Every project's state, keyed by "Project: slug (/root)".
        def all_states
          State.all.to_h do |slug, root|
            title = ["Project: #{slug} (#{root})", ("[root missing]" unless File.directory?(root))].compact.join(" ")
            [title, State.new(project: slug, root:)]
          end
        end

        def record_for!(name) = state.read_record(name) || abort("jobs: no such job: #{name} (see `asgard jobs list`)")

        def stopper = Stopper.new(timeout: options[:timeout] || Stopper::TIMEOUT)

        # The records `stop` ends, newest start first, and the names that
        # matched nothing. A task name reaches the jobs of every task it
        # depends on, which needs this project's .loki loaded.
        def stop_targets(names)
          records, unknown =
            if every_project? then [all_states.values.flat_map(&:records), []]
            elsif names.empty? then [state.records, []]
            else Jobs.resolve(names, state.records, closure: ->(task) { Jobs.closure(task, Tasks._deps) })
            end
          [records.sort_by { |record| [record[:started].to_s, record[:name].to_s] }.reverse, unknown]
        end

        def no_jobs_message
          return "No jobs have been started on this machine." if every_project?

          "No jobs recorded for #{jobs_project}. Start one with `sh \"...\", background: true` inside a task.\n" \
            "Use `asgard jobs list --all` to see every project's jobs."
        end
      end

      desc "list", "Show this project's jobs: running, exited with a status, or gone (--all: every project's)"
      method_option :all, aliases: "-a", type: :boolean, desc: "List every project's jobs, not just this one's"
      def list
        states = every_project? ? all_states : { nil => state }
        Commands.skipped_lines(states.values).each { |line| $stderr.puts line }
        groups = states.transform_values { |each_state| Commands.rows(each_state) }.reject { |_, rows| rows.empty? }
        return puts(no_jobs_message) if groups.empty?

        puts groups.map { |title, rows| Schedule::Table.draw(rows, title:, headers: HEADERS, keys: KEYS, flexible: FLEXIBLE) }.join("\n\n")
        puts "\nState: #{State.base_dir}"
      end

      desc "stop [NAME...]", "Stop jobs by job name or by task (and the tasks it depends on); no name stops every job of this project"
      method_option :all, aliases: "-a", type: :boolean, desc: "Stop every project's jobs"
      method_option :timeout, aliases: "-t", type: :numeric, desc: "Seconds to wait after TERM before KILL (default #{Stopper::TIMEOUT})"
      def stop(*names)
        abort "jobs: stop --all takes no job names; name the jobs without --all" if options[:all] && names.any?
        records, unmatched = stop_targets(names)
        idle, unknown = unmatched.partition { |name| Tasks.all_commands.key?(name) }
        idle.each { |name| puts "#{name} has no running jobs" }
        unknown.each { |name| $stderr.puts "jobs: no such job or task: #{name}" }
        puts "No jobs recorded for #{jobs_project}." if records.empty? && unmatched.empty?
        outcomes = records.map { |record| stopper.stop_and_report(record) }
        exit 1 if unknown.any? || outcomes.include?(:killed)
      end

      desc "log NAME", "Print one job's log (stdout and stderr of its latest run; each start empties it)"
      method_option :follow, aliases: "-f", type: :boolean, desc: "Keep printing new output as it arrives (tail -f)"
      def log(name)
        path = record_for!(name)[:log]
        return $stderr.puts "#{name} has no log yet (#{path})." unless File.exist?(path)
        return exec(*Commands.tail_argv(path)) if options[:follow]

        IO.copy_stream(path, $stdout)
      end

      desc "restart NAME", "Stop the job, then run its owning task again"
      method_option :timeout, aliases: "-t", type: :numeric, desc: "Seconds to wait after TERM before KILL (default #{Stopper::TIMEOUT})"
      def restart(name)
        record = record_for!(name)
        task   = record[:task].to_s
        abort "jobs: #{name} was not started from a task, so there is nothing to run again" if task.empty?
        stopper.stop_and_report(record)
        Tasks._reset_ran!
        Tasks.start([task])
      end

      desc "clean", "Forget every job that is no longer running: its record, script, status and log"
      # Each removal re-checks under the job's start lock (see
      # State#forget_unless_active), so a start that ran meanwhile wins.
      def clean
        invalid = state.invalid_records.map { |path| [File.basename(path, ".json"), " (not a job record)"] }
        gone    = state.records.reject { |record| state.active?(record) }.map { |record| [record[:name], ""] }
        removed = (invalid + gone).select { |name, _| state.forget_unless_active(name) }
        return puts("Nothing to clean for #{jobs_project}.") if removed.empty?

        removed.each { |name, note| puts "removed #{name}#{note}" }
      end
    end
  end
end
# rubocop:enable Style/StderrPuts
