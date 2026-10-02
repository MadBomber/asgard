# frozen_string_literal: true

require "open3"
require "shellwords"

module Asgard
  # Scheduled asgard tasks, run by the platform's own scheduler: launchd on
  # macOS (Schedule::Launchd), systemd user timers on Linux
  # (Schedule::Systemd). Both run a calendar job missed while the machine
  # slept as soon as it wakes.
  #
  # This file is the platform-neutral half: it validates `schedule`
  # declarations and builds the command a job runs. Everything here is pure,
  # so each method can be tested on its own.
  #
  # Every backend implements the same instance API, which is all
  # Schedule::Commands uses:
  #
  #   Backend.new(project:, root:, home: Dir.home, runner: Schedule.runner)
  #   #scheduler                          # => "launchd" / "systemd"
  #   #files(spec, asgard:, direnv:)      # => { path => content } install would write
  #   #install(spec, asgard:, direnv:)    # write + load; => :active, or :stopped if stopped earlier
  #   #uninstall(name)                    # unload, clear any stop, delete files
  #   #start(name) / #stop(name)          # stop persists across reboots and reinstalls
  #   #trigger(name)                      # run once now, under the scheduler
  #   #installed_names                    # => ["demo", ...] for this project
  #   #installed_entries                  # => [[project_slug, "demo"], ...] for every project
  #   #installed_columns(name)            # => { command:, schedule: } read back from the job files, or nil
  #   #installed_directory(name)          # => the project root the job runs in, or nil
  #   #status(name)                       # => { state: :active|:stopped|:not_loaded, last_exit: String|nil }
  #   #log_path(name)                     # => path the job's output is appended to
  #   #notes                              # => [String] platform hints to show after install
  module Schedule
    # A scheduler command (launchctl, systemctl) failed.
    class Error < Asgard::Error; end

    # Weekday numbers follow launchd and cron: 0 (Sunday) through 6 (Saturday).
    DAYS = %i[sunday monday tuesday wednesday thursday friday saturday].freeze

    DAY_GROUPS = {
      weekdays: %i[monday tuesday wednesday thursday friday],
      weekends: %i[saturday sunday]
    }.freeze

    # Default command runner for the backends: argv in, [output, success?] out.
    RUNNER = lambda do |*argv|
      out, status = Open3.capture2e(*argv)
      [out, status.success?]
    rescue SystemCallError => e
      [e.message, false]
    end

    class << self
      # The runner new backends get. Tests assign one that records commands
      # instead of running them; nil restores RUNNER.
      attr_writer :runner

      def runner = @runner || RUNNER

      # The backend class for +platform+ (a RUBY_PLATFORM string).
      def backend_class(platform = RUBY_PLATFORM)
        case platform
        when /darwin/ then Launchd
        when /linux/  then Systemd
        else raise Error, "#{platform} is not supported (needs macOS launchd or Linux systemd)"
        end
      end
    end

    module_function

    # Validates a declaration and returns it as a plain Hash. options: is the
    # task's command-line options as a String, split shell-style with quotes
    # respected ("--period week --title 'Week End'"), or an Array of words.
    # Exactly one of at: ("HH:MM" or an Array of them, with on:) or every:
    # (seconds or a Duration) is required. as: names the entry.
    def normalize(task, options: nil, at: nil, on: :daily, every: nil, env: {}, as: nil)
      task = task.to_s
      unless task.match?(/\A[\w:-]+\z/)
        raise ArgumentError,
              "schedule: task name #{task.inspect} must be a single word; put its flags in options:"
      end
      raise ArgumentError, "schedule :#{task} needs either at: or every:, not both" unless at.nil? ^ every.nil?

      if every
        every = seconds(every)
        unless every&.positive?
          raise ArgumentError,
                "schedule :#{task} every: must be a positive number of seconds or a Duration (3.minutes)"
        end
      else
        calendar(at:, on:) # raises on a bad time or day
      end

      args = options.is_a?(Array) ? options.map(&:to_s) : Shellwords.split(options.to_s)
      { name: entry_name(task, args, as), task:, args:, at:, on:, every:, env: env.to_h { |key, value| [key.to_s, value.to_s] } }
    end

    # Integer seconds from an Integer or anything Duration-like (ActiveSupport's
    # 3.minutes responds to in_seconds); nil for anything else.
    def seconds(value)
      return value if value.is_a?(Integer)

      value.respond_to?(:in_seconds) ? value.in_seconds.to_i : nil
    end

    # The task alone, or a slug of the whole command when it has arguments,
    # so one task can be scheduled more than once with different flags.
    def entry_name(task, args, as = nil)
      name = (as || (args.empty? ? task : slug([task, *args].join(" ")))).to_s
      raise ArgumentError, "schedule as: #{name.inspect} may only contain letters, digits, _ . -" unless name.match?(/\A[\w.-]+\z/)

      name
    end

    def slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")

    # For display: the command line the job runs.
    def command_line(task, args = []) = Shellwords.join(["asgard", task.to_s, *args])

    def describe(at: nil, on: :daily, every: nil, **)
      return "every #{every}s" if every

      "#{Array(at).join(', ')} #{Array(on).join(', ')}"
    end

    # For the `list` table: like describe, but a run of hourly times
    # collapses ("10:00, 11:00 ... 17:00" => "10:00-17:00 hourly").
    def describe_compact(at: nil, on: :daily, every: nil, **)
      return "every #{every}s" if every

      "#{compact_times(Array(at))} #{Array(on).join(', ')}"
    end

    # The command and schedule columns of a `list` row for a declared entry.
    def list_columns(spec) = { command: command_line(spec[:task], spec[:args]), schedule: describe_compact(**spec) }

    # The command and schedule columns of a `list` row: the declaration's, or
    # `missing` in the schedule column when there is none.
    def declared_columns(spec, missing) = spec ? list_columns(spec) : { command: "-", schedule: missing }

    # The state and last-exit columns of a `list` row, from a backend's live status.
    def live_columns(backend, name)
      state, last_exit = backend.status(name).values_at(:state, :last_exit)
      { state: state.to_s.tr("_", " "), last_exit: state == :active ? (last_exit || "never run") : "-" }
    end

    # The command a job runs, from its program arguments: everything from
    # `asgard` on, so a direnv wrapper and the asgard install path drop out.
    def command_from_arguments(arguments)
      start = arguments.index { |word| File.basename(word) == "asgard" }
      Shellwords.join(["asgard", *arguments.drop(start ? start + 1 : 0)])
    end

    # describe_compact for calendar entries (the shape `calendar` returns), one
    # group per distinct set of days: "17:30 weekdays; 09:00 saturday".
    def describe_calendar(entries)
      entries.group_by { |entry| entry[:days]&.sort }.map { |days, group| describe_days(days, group) }.join("; ")
    end

    def describe_days(days, group)
      describe_compact(at: group.map { |entry| format("%<hour>02d:%<minute>02d", entry) }, on: day_names(days))
    end

    # The command and schedule columns for a job read back from its files.
    def installed_columns(arguments:, calendar:, every:)
      { command: command_from_arguments(arguments), schedule: every ? "every #{every}s" : describe_calendar(calendar) }
    end

    # Weekday numbers back to what on: took: nil => :daily, [1, 2, 3, 4, 5] => :weekdays, [5] => [:friday].
    def day_names(days)
      return :daily unless days

      names = days.map { |day| DAYS.fetch(day) }
      DAY_GROUPS.key(names) || names
    end

    def compact_times(times)
      parsed = times.map { |time| parse_time(time) }
      hourly = parsed.size >= 3 && parsed.map(&:last).uniq.size == 1 &&
               parsed.each_cons(2).all? { |(hour, _), (next_hour, _)| next_hour == hour + 1 }
      hourly ? "#{times.first}-#{times.last} hourly" : times.join(", ")
    end

    # "17:30" => [17, 30]
    def parse_time(time)
      shown = time.inspect
      match = /\A(\d{1,2}):(\d{2})\z/.match(time.to_s) or
        raise ArgumentError, %(at: expects "HH:MM" (got #{shown}))
      hour = match[1].to_i
      minute = match[2].to_i
      raise ArgumentError, "at: #{shown} is not a valid time" unless hour <= 23 && minute <= 59

      [hour, minute]
    end

    # :daily => nil (every day); :weekdays => [1, 2, 3, 4, 5]; :friday => [5];
    # %i[monday thursday] => [1, 4]
    def weekdays(on)
      return nil if on.to_s == "daily"

      names = DAY_GROUPS.fetch(on.is_a?(Array) ? nil : on.to_sym) { Array(on) }
      names.map do |day|
        DAYS.index(day.to_sym) or raise ArgumentError, "on: unknown day #{day.inspect}"
      end
    end

    # One entry per time: [{ hour: 17, minute: 30, days: [1, 2, 3, 4, 5] }];
    # days is nil for every day.
    def calendar(at:, on: :daily)
      days = weekdays(on)
      Array(at).map do |time|
        hour, minute = parse_time(time)
        { hour:, minute:, days: }
      end
    end

    # PATH captured at install time, plus the declaration's env:.
    def environment(spec, path = ENV.fetch("PATH", nil)) = { "PATH" => path.to_s }.merge(spec[:env])

    # First executable named +command+ on +path+ (a PATH-style String), or nil.
    def which(command, path)
      path.to_s.split(File::PATH_SEPARATOR)
          .map { |dir| File.join(dir, command) }
          .find { |file| File.file?(file) && File.executable?(file) }
    end

    # The job's argv. Schedulers need an absolute program. With direnv, the
    # repo's .envrc (API keys, ...) is loaded at run time instead of being
    # copied into the job definition, and direnv finds asgard on the job's
    # PATH. Each argument is its own element, so no shell re-splits them.
    def program_arguments(task, args = [], root:, asgard:, direnv: nil)
      argv = [task.to_s, *args.map(&:to_s)]
      direnv ? [direnv, "exec", root, "asgard", *argv] : [asgard, *argv]
    end
  end
end
