# frozen_string_literal: true

require "fileutils"
require "etc"

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

      # A double-quoted word for ExecStart=/Environment=. $ is doubled too so
      # ExecStart= doesn't expand it as a variable.
      def self.quote(text)
        %("#{escape_specifiers(text).gsub('\\') { '\\\\' }.gsub('"', '\\"').gsub('$', '$$')}")
      end

      def self.service_unit(description:, arguments:, working_directory:, environment:, log_path:)
        env_lines = environment.map { |key, value| "Environment=#{quote("#{key}=#{value}")}" }
        log       = escape_specifiers(log_path)
        <<~UNIT
          [Unit]
          Description=#{escape_specifiers(description)}

          [Service]
          Type=oneshot
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

      # `systemctl show -p A -p B` output => { "A" => "...", "B" => "..." }
      def self.parse_show(output) = output.lines.to_h { |line| line.chomp.split("=", 2) }.reject { |k, _| k.to_s.empty? }

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

      # A timer that exists but is disabled was stopped on purpose; keep it so.
      def install(spec, asgard:, direnv:)
        name       = spec[:name]
        timer_file = timer_path(name)
        timer_unit = timer(name)
        stopped    = File.exist?(timer_file) && !enabled?(name)
        FileUtils.mkdir_p [File.dirname(timer_file), File.dirname(log_path(name))]
        files(spec, asgard:, direnv:).each { |path, content| File.write(path, content) }
        systemctl! "daemon-reload"
        return :stopped if stopped

        systemctl! "enable", timer_unit
        systemctl! "restart", timer_unit # picks up a changed schedule
        :active
      end

      def uninstall(name)
        service_unit = service(name)
        systemctl "disable", "--now", timer(name)
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

      def status(name)
        _, active = systemctl("is-active", "--quiet", timer(name))
        state = if active then :active
                elsif enabled?(name) then :not_loaded
                else :stopped
                end
        out, = systemctl("show", service(name), "-p", "ExecMainStatus", "-p", "ExecMainExitTimestampMonotonic")
        props = self.class.parse_show(out)
        stamp = props["ExecMainExitTimestampMonotonic"].to_s
        ran   = !stamp.empty? && stamp != "0"
        { state:, last_exit: ran ? props["ExecMainStatus"] : nil }
      end

      def notes
        out, ok = run("loginctl", "show-user", @user.to_s, "-p", "Linger", "--value")
        return [] unless ok && out.strip == "no"

        ["systemd: user timers only run while #{@user} is logged in; run `loginctl enable-linger` to keep them running."]
      end

      private

      def timer(name) = "#{unit(name)}.timer"

      def service(name) = "#{unit(name)}.service"

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
