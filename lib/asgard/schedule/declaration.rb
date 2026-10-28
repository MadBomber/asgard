# frozen_string_literal: true

require "digest"
require "open3"
require "shellwords"
require "zlib"

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
  #   #status(name)                       # => { state: :active|:running|:stopped|:not_loaded, last_exit: String|nil }
  #                                       #    last_exit: an exit code ("1") or a signal ("signal 15 (Terminated)")
  #   #log_path(name)                     # => path the job's output is appended to
  #   #notes                              # => [String] platform hints to show after install
  module Schedule
    # A scheduler command (launchctl, systemctl) failed.
    class Error < Asgard::Error; end

    # Weekday numbers follow launchd and cron: 0 (Sunday) through 6 (Saturday).
    DAYS = %i[sunday monday tuesday wednesday thursday friday saturday].freeze

    # Longest derived entry name, hash suffix included, so a job's file
    # names stay well inside the 255-byte limit.
    NAME_MAX = 64

    # Options a slug spells out: lowercase words and flags. Any other option
    # (--period=week, 'Week End') adds a hash suffix, so spellings that slug
    # alike still name different entries.
    PLAIN_ARG = /\A-{0,2}[a-z0-9]+(?:-[a-z0-9]+)*\z/

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
    # (seconds or a Duration) is required; on: goes only with at:. as: names
    # the entry.
    def normalize(task, options: nil, at: nil, on: nil, every: nil, env: {}, as: nil)
      task = task_name(task)
      raise ArgumentError, "schedule :#{task} needs either at: or every:, not both" unless at.nil? ^ every.nil?

      if every
        raise ArgumentError, "schedule :#{task} on: only applies to at: times; every: runs on every day" if on

        every = seconds(every)
        unless every&.positive?
          raise ArgumentError,
                "schedule :#{task} every: must be a positive number of seconds or a Duration (3.minutes)"
        end
      else
        on ||= :daily
        calendar(at:, on:) # raises on a bad time or day
      end

      args = options.is_a?(Array) ? options.map(&:to_s) : Shellwords.split(options.to_s)
      args.each { |arg| reject_control_characters!(task, "options:", arg) }
      { name: entry_name(task, args, as), task:, args:, at:, on:, every:, env: environment_variables(task, env) }
    end

    # The command a declaration names, as Thor dispatches it: a dash is the
    # underscore of the method name (`asgard daily-summary` runs
    # daily_summary). A colon would name a subcommand, which is its own
    # command word plus arguments.
    def task_name(task)
      name = task.to_s
      if name.include?(":")
        raise ArgumentError,
              "schedule: #{name.inspect} names a subcommand; schedule its command and pass the rest in options: " \
              "(schedule :#{name.split(':').first}, options: #{name.split(':', 2).last.inspect}, ...)"
      end
      unless name.match?(/\A[\w-]+\z/)
        raise ArgumentError, "schedule: task name #{name.inspect} must be a single word; put its flags in options:"
      end

      name.tr("-", "_")
    end

    # env: as String pairs. Names must be shell-style identifiers, and no
    # name, value or option may hold a control character other than tab: a
    # newline would end the line it is written on in a unit file and start
    # another directive, and plists cannot hold most of them at all.
    def environment_variables(task, env)
      env.to_h do |key, value|
        key = key.to_s
        raise ArgumentError, "schedule :#{task} env: #{key.inspect} is not a variable name" unless key.match?(/\A[A-Za-z_]\w*\z/)

        value = value.to_s
        reject_control_characters!(task, "env: #{key}", value)
        [key, value]
      end
    end

    def reject_control_characters!(task, what, text)
      return unless text.match?(/[\x00-\x08\x0a-\x1f\x7f]/)

      raise ArgumentError, "schedule :#{task} #{what} holds a control character (#{text.inspect})"
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
      name = (as || (args.empty? ? task : command_slug(task, args))).to_s
      raise ArgumentError, "schedule as: #{name.inspect} may only contain letters, digits, _ . -" unless name.match?(/\A[\w.-]+\z/)

      name
    end

    # "report-period-week". A short hash of the exact words is appended when
    # the slug would lose something (an option that isn't PLAIN_ARG, or more
    # than NAME_MAX characters), so different commands never share a name.
    def command_slug(task, args)
      words = [task, *args].map(&:to_s)
      name  = slug(words.join(" "))
      return name if name.length <= NAME_MAX && words.drop(1).all? { |arg| arg.match?(PLAIN_ARG) }

      digest = Digest::SHA256.hexdigest(words.join("\0"))[0, 8]
      "#{name[0, NAME_MAX - 9].delete_suffix('-')}-#{digest}"
    end

    def slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")

    # The slug a project's jobs and watcher state are filed under: the
    # basename of its root plus the CRC32 of the real path in hex
    # ("api-9f3a1c2b"), so two projects in directories of the same name
    # never share labels, units or state. Symlinked paths to one project
    # agree, since the real path is hashed.
    def project_slug(root)
      real = File.realpath(root.to_s)
      "#{slug(File.basename(real))}-#{format('%08x', Zlib.crc32(real))}"
    end

    # Whether +slug+ is the project the user named: the whole slug, or its
    # basename alone when that is enough to pick it out.
    def project_match?(slug, name) = slug == name || slug.sub(/-\h{8}\z/, "") == name

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
      { state: state.to_s.tr("_", " "), last_exit: %i[active running].include?(state) ? (last_exit || "never run") : "-" }
    end

    # The [slug, name] entries whose job files name a project directory
    # that no longer exists: the project moved or was deleted, and its jobs
    # fire in a directory that is not there. An entry whose directory
    # cannot be read is left alone.
    def orphaned_entries(entries, directory_of:, exists: File.method(:directory?))
      entries.select do |slug, name|
        dir = directory_of.call(slug, name)
        dir && !exists.call(dir)
      end
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
      DAY_GROUPS.find { |_group, members| members.sort == names.sort }&.first || names
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
      raise ArgumentError, "on: needs at least one day" if names.empty?

      names.map do |day|
        DAYS.index(day.to_sym) or raise ArgumentError, "on: unknown day #{day.inspect}"
      end
    end

    # One entry per time: [{ hour: 17, minute: 30, days: [1, 2, 3, 4, 5] }];
    # days is nil for every day.
    def calendar(at:, on: :daily)
      raise ArgumentError, "at: needs at least one time" if Array(at).empty?

      days = weekdays(on)
      Array(at).map do |time|
        hour, minute = parse_time(time)
        { hour:, minute:, days: }
      end
    end

    # A job's last exit when a signal ended it: "signal 15 (Terminated)".
    def signal_exit(number, name) = "signal #{number} (#{name})"

    # Raises when a job file's name passes the 255-byte filename limit.
    def check_lengths!(paths)
      long = paths.map { |path| File.basename(path) }.find { |base| base.bytesize > 255 }
      raise Error, "schedule: job file name is too long (#{long.bytesize} bytes, limit 255): #{long}; use a shorter as: name" if long
    end

    # Runs the block that writes job files; a failure there (the system
    # message names the path) is a Schedule::Error, not a backtrace.
    def writing
      yield
    rescue SystemCallError => e
      raise Error, "schedule: could not write job files: #{e.message}"
    end

    # Writes a job file only its owner can read: it holds the env: values.
    def write_private(path, content)
      File.write(path, content, perm: 0o600)
      File.chmod(0o600, path) # perm: applies only when the file is created
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
