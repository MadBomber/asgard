# frozen_string_literal: true

require "fileutils"
require "etc"
require_relative "job_files"

module Asgard
  module Schedule
    # Linux backend: each declaration becomes a systemd user service + timer
    # pair (~/.config/systemd/user/asgard.<project>.<name>.{service,timer}).
    # Calendar timers are Persistent=, so a run missed while the machine was
    # off or asleep happens on the next boot/wake. Requires systemd 240+ (for
    # StandardOutput=append:). User timers only run while you are logged in
    # unless lingering is enabled (`loginctl enable-linger`); #notes says so.
    # Implements the backend API documented in declaration.rb.
    class Systemd
      UNIT_PREFIX = "asgard"
      DAY_ABBREVIATIONS = %w[Sun Mon Tue Wed Thu Fri Sat].freeze
      # The service properties status asks `systemctl show` for.
      SHOW_PROPERTIES = %w[ActiveState SubState ExecMainCode ExecMainStatus ExecMainExitTimestampMonotonic].freeze

      # ---- pure helpers -----------------------------------------------------

      def self.unit_prefix(project) = "#{UNIT_PREFIX}.#{Schedule.slug(project)}."

      def self.unit(project, name) = "#{unit_prefix(project)}#{name}"

      # { hour: 17, minute: 30, days: [1, 5] } => "Mon,Fri *-*-* 17:30:00"
      def self.on_calendar(entry)
        days = entry[:days]&.map { |day| DAY_ABBREVIATIONS.fetch(day) }&.join(",")
        [days, format("*-*-* %<hour>02d:%<minute>02d:00", entry)].compact.join(" ")
      end

      # systemd expands %specifiers everywhere; % must be doubled to be literal.
      def self.escape_specifiers(text) = text.to_s.gsub("%", "%%")

      # A double-quoted word for ExecStart=. $ is doubled too so ExecStart=
      # doesn't expand it as a variable.
      def self.quote(text) = %("#{quote_body(text).gsub('$', '$$')}")

      # A double-quoted Environment= assignment. Environment= does no
      # variable expansion, so a $ there is already literal and doubling it
      # would leave $$ in the value (systemd.exec(5)).
      def self.quote_env(text) = %("#{quote_body(text)}")

      # % doubled, \ and " backslash-escaped: what both kinds of quoting share.
      def self.quote_body(text) = escape_specifiers(text).gsub('\\') { '\\\\' }.gsub('"', '\\"')

      # KillMode=process: when the run ends, systemd kills only the task's own
      # process, so background jobs it started (setsid alone can't leave the
      # unit's cgroup) keep running, as they do under launchd.
      def self.service_unit(description:, arguments:, working_directory:, environment:, log_path:)
        env_lines = environment.map { |key, value| "Environment=#{quote_env("#{key}=#{value}")}" }
        log       = escape_specifiers(log_path)
        <<~UNIT
          [Unit]
          Description=#{escape_specifiers(description)}

          [Service]
          Type=oneshot
          KillMode=process
          WorkingDirectory=#{escape_specifiers(working_directory)}
          #{env_lines.join("\n")}
          ExecStart=#{arguments.map { |arg| quote(arg) }.join(' ')}
          StandardOutput=append:#{log}
          StandardError=append:#{log}
        UNIT
      end

      # every: runs one interval after the timer starts, then one interval
      # after each run, matching launchd's StartInterval.
      def self.timer_unit(description:, service:, calendar: nil, every: nil)
        schedule = if every
                     ["OnActiveSec=#{every}", "OnUnitActiveSec=#{every}"]
                   else
                     [*calendar.map { |entry| "OnCalendar=#{on_calendar(entry)}" }, "Persistent=true"]
                   end
        <<~UNIT
          [Unit]
          Description=#{escape_specifiers(description)}

          [Timer]
          #{schedule.join("\n")}
          AccuracySec=1s
          Unit=#{service}

          [Install]
          WantedBy=timers.target
        UNIT
      end

      # ExecStart= words, undoing `quote`.
      def self.parse_exec_start(service)
        line = service[/^ExecStart=(.*)$/, 1].to_s
        line.scan(/"((?:[^"\\]|\\.)*)"/).flatten.map { |word| word.gsub(/\\(.)/, '\1').gsub("$$", "$").gsub("%%", "%") }
      end

      # "Mon,Fri *-*-* 17:30:00" => { hour: 17, minute: 30, days: [1, 5] }
      def self.parse_on_calendar(text)
        days = text[/\A([A-Z][a-z]{2}(?:,[A-Z][a-z]{2})*) /, 1]
        hour, minute = text.scan(/(\d+):(\d+)/).first.map(&:to_i)
        { hour:, minute:, days: days&.split(",")&.map { |abbr| DAY_ABBREVIATIONS.index(abbr) } }
      end

      # The WorkingDirectory= (the project root) of a service unit, or nil.
      def self.parse_directory(service) = service[/^WorkingDirectory=(.*)$/, 1]&.gsub("%%", "%")

      # { calendar: [entry], every: Integer|nil } from a timer unit.
      def self.parse_timer(timer)
        {
          calendar: timer.scan(/^OnCalendar=(.*)$/).flatten.map { |text| parse_on_calendar(text) },
          every:    timer[/^OnUnitActiveSec=(\d+)/, 1]&.to_i
        }
      end

      # `systemctl show -p A -p B` output => { "A" => "...", "B" => "..." }
      def self.parse_show(output) = output.lines.to_h { |line| line.chomp.split("=", 2) }.reject { |k, _| k.to_s.empty? }

      # parse_show of SHOW_PROPERTIES => { running: Boolean, last_exit: String|nil }.
      # A oneshot service is "activating" while its command runs. ExecMainCode
      # 2 (killed) or 3 (dumped) means ExecMainStatus is a signal number.
      def self.service_status(props)
        stamp  = props["ExecMainExitTimestampMonotonic"].to_s
        status = props["ExecMainStatus"] unless stamp.empty? || stamp == "0"
        signal = status if %w[2 3].include?(props["ExecMainCode"])
        {
          running:   props["ActiveState"] == "activating" || props["SubState"] == "running",
          last_exit: signal ? Schedule.signal_exit(signal, "SIG#{Signal.signame(signal.to_i)}") : status
        }
      end

      # The { path => content } entries whose file is missing or differs.
      def self.changed_files(files) = files.reject { |path, content| File.exist?(path) && File.read(path) == content }

      # ---- backend API ------------------------------------------------------

      def initialize(project:, root:, home: Dir.home, runner: Schedule.runner, env: ENV, user: Etc.getpwuid(Process.uid).name)
        @project = project
        @root    = root
        @runner  = runner
        @user    = user
        @config  = env["XDG_CONFIG_HOME"] || File.join(home, ".config")
        @state   = env["XDG_STATE_HOME"] || File.join(home, ".local", "state")
      end

      def scheduler = "systemd"

      def unit(name) = self.class.unit(@project, name)

      def service_path(name) = File.join(@config, "systemd", "user", "#{unit(name)}.service")

      def timer_path(name) = File.join(@config, "systemd", "user", "#{unit(name)}.timer")

      def log_path(name) = File.join(@state, "asgard", "#{unit(name)}.log")

      def files(spec, asgard:, direnv:)
        name, task, args, every = spec.values_at(:name, :task, :args, :every)
        klass       = self.class
        description = "#{Schedule.command_line(task, args)} (#{@project})"
        service = klass.service_unit(
          description:,
          arguments:         Schedule.program_arguments(task, args, root: @root, asgard:, direnv:),
          working_directory: @root,
          environment:       Schedule.environment(spec),
          log_path:          log_path(name)
        )
        timer = klass.timer_unit(
          description:,
          service:  "#{unit(name)}.service",
          calendar: every ? nil : Schedule.calendar(at: spec[:at], on: spec[:on]),
          every:
        )
        { service_path(name) => service, timer_path(name) => timer }
      end

      # A timer that exists but is disabled was stopped on purpose; keep it
      # so. That is only true once an install has finished, so a first
      # install that fails takes its unit files back out. Unchanged units are
      # left alone: restarting a timer would restart an every: countdown, and
      # `start` is a no-op for a timer already running.
      def install(spec, asgard:, direnv:)
        name       = spec[:name]
        timer_file = timer_path(name)
        timer_unit = timer(name)
        job        = files(spec, asgard:, direnv:)
        Schedule.check_lengths!([*job.keys, log_path(name)])
        first      = !File.exist?(timer_file)
        stopped    = !first && !enabled?(name)
        changed    = write_changed(job, name).any?
        systemctl! "daemon-reload" if changed
        return :stopped if stopped

        systemctl! "enable", timer_unit
        systemctl! changed ? "restart" : "start", timer_unit # restart picks up a changed schedule
        :active
      rescue Error
        FileUtils.rm_f([service_path(name), timer_file]) if first
        raise
      end

      # A timer that won't disable is left installed, files and all, rather
      # than deleted while systemd keeps it running.
      def uninstall(name)
        service_unit = service(name)
        systemctl! "disable", "--now", timer(name)
        systemctl "stop", service_unit
        FileUtils.rm_f [service_path(name), timer_path(name)]
        systemctl "daemon-reload"
        systemctl "reset-failed", service_unit
      end

      def start(name) = systemctl!("enable", "--now", timer(name))

      def stop(name) = systemctl!("disable", "--now", timer(name))

      def trigger(name) = systemctl!("start", "--no-block", service(name))

      def installed_names
        prefix = self.class.unit_prefix(@project)
        Dir.glob(timer_path("*")).map { |path| File.basename(path, ".timer").delete_prefix(prefix) }.sort
      end

      # Every asgard entry on this machine, whatever its project: [[project_slug, name], ...].
      def installed_entries = JobFiles.entries_in(File.join(@config, "systemd", "user"), prefix: UNIT_PREFIX, ext: ".timer")

      # { command:, schedule: } as installed, read from the unit files; nil when there are none.
      def installed_columns(name)
        paths = [service_path(name), timer_path(name)]
        return unless paths.all? { |path| File.exist?(path) }

        klass = self.class
        service, timer = paths.map { |path| File.read(path) }
        Schedule.installed_columns(arguments: klass.parse_exec_start(service), **klass.parse_timer(timer))
      end

      # The project root the job runs in, read from the service unit; nil when there isn't one.
      def installed_directory(name) = JobFiles.directory(service_path(name), self.class.method(:parse_directory))

      def status(name)
        _, active = systemctl("is-active", "--quiet", timer(name))
        state = if active then :active
                elsif enabled?(name) then :not_loaded
                else :stopped
                end
        klass = self.class
        out,  = systemctl("show", service(name), *SHOW_PROPERTIES.flat_map { |prop| ["-p", prop] })
        running, last_exit = klass.service_status(klass.parse_show(out)).values_at(:running, :last_exit)
        { state: running ? :running : state, last_exit: }
      end

      def notes
        out, ok = run("loginctl", "show-user", @user.to_s, "-p", "Linger", "--value")
        return [] unless ok && out.strip == "no"

        ["systemd: user timers only run while #{@user} is logged in; run `loginctl enable-linger` to keep them running."]
      end

      private

      def timer(name) = "#{unit(name)}.timer"

      def service(name) = "#{unit(name)}.service"

      # Writes the unit files whose content changed (and the log directory);
      # returns them as { path => content }.
      def write_changed(job, name)
        changed = self.class.changed_files(job)
        Schedule.writing do
          FileUtils.mkdir_p [File.dirname(timer_path(name)), File.dirname(log_path(name))]
          changed.each { |path, content| Schedule.write_private(path, content) }
        end
      end

      def enabled?(name) = systemctl("is-enabled", "--quiet", timer(name)).last

      def systemctl(*) = run("systemctl", "--user", *)

      def systemctl!(*args)
        out, ok = systemctl(*args)
        raise Error, "systemctl --user #{args.join(' ')} failed: #{out.strip}" unless ok

        out
      end

      def run(*argv) = @runner.call(*argv)
    end
  end
end
