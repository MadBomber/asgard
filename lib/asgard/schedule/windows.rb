# frozen_string_literal: true

require "fileutils"

module Asgard
  module Schedule
    # Windows backend: each declaration becomes a Task Scheduler task,
    # \asgard\<project>\<name>, registered from an XML definition kept in
    # %LOCALAPPDATA%\asgard\tasks. Tasks are StartWhenAvailable, so a run
    # missed while the machine was off happens at the next boot. Everything
    # goes through schtasks.exe. A task runs as the installing user, in
    # their interactive session, so only while they are logged on.
    #
    # Task Scheduler cannot redirect a task's output, so the action is
    # cmd.exe running the job with its output appended to the log file; the
    # job's environment is `set` on the same command line, since a task
    # definition has no environment block. Implements the backend API
    # documented in declaration.rb.
    class Windows
      FOLDER       = "\\asgard"
      NAMESPACE    = "http://schemas.microsoft.com/windows/2004/02/mit/task"
      DAY_ELEMENTS = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze

      # A StartBoundary without an offset is local time; one in the past
      # just means "from now on".
      EPOCH = "2000-01-01"

      # schtasks reports this Last Result for a task that has never run.
      NEVER_RAN = "267011"

      # ---- pure helpers -----------------------------------------------------

      def self.task_folder(project) = "#{FOLDER}\\#{Schedule.slug(project)}"

      def self.task_name(project, name) = "#{task_folder(project)}\\#{name}"

      def self.windows_path(path) = path.to_s.tr("/", "\\")

      # A word for a cmd.exe command line. A double quote has no escape that
      # both cmd.exe and the C runtime agree on, so one is refused outright.
      def self.quote(word)
        text = word.to_s
        text.empty? || text.match?(/[\s&|<>^()]/) ? quoted(text) : text
      end

      def self.quoted(text)
        raise Error, "windows: #{text.inspect} cannot be passed to a task; cmd.exe has no safe escape for a quote" if text.include?('"')

        %("#{text}")
      end

      # What cmd.exe runs: the job's environment set first (`set "K=V"` keeps
      # cmd from reading the value), then the program, output appended to the log.
      def self.command_line(arguments:, environment:, log_path:)
        sets = environment.map { |key, value| "set #{quoted("#{key}=#{value}")} && " }.join
        "/c #{sets}#{arguments.map { |word| quote(word) }.join(' ')} >> #{quoted(windows_path(log_path))} 2>&1"
      end

      # cmd.exe words as [quoted, bare] pairs, one of each nil.
      def self.tokens(text) = text.scan(/"([^"]*)"|(\S+)/)

      # The program and its arguments back out of a command line that
      # `command_line` built: the words after the last bare && and before >>.
      def self.parse_arguments(text)
        words = tokens(text)
        start = words.rindex([nil, "&&"])&.+(1) || 1 # 1 skips /c
        stop  = words.rindex([nil, ">>"]) || words.size
        words[start...stop].map { |quoted, bare| quoted || bare }
      end

      def self.start_boundary(hour: 0, minute: 0, **) = format("#{EPOCH}T%<hour>02d:%<minute>02d:00", hour:, minute:)

      # { hour: 17, minute: 30, days: [1, 5] } => a weekly trigger; days nil => daily.
      def self.calendar_trigger(entry)
        days     = entry[:days]
        schedule = if days
                     elements = days.map { |day| "<#{DAY_ELEMENTS.fetch(day)}/>" }.join
                     "<ScheduleByWeek><DaysOfWeek>#{elements}</DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek>"
                   else
                     "<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>"
                   end
        "<CalendarTrigger><StartBoundary>#{start_boundary(**entry)}</StartBoundary>#{schedule}</CalendarTrigger>"
      end

      # every: as a repeating trigger. Task Scheduler repeats at minute
      # resolution, for intervals up to 31 days.
      def self.time_trigger(every)
        unless every >= 60 && (every % 60).zero? && every <= 31 * 86_400
          raise Error, "windows: cannot run every #{every}s; Task Scheduler repeats every whole minute up to 31 days"
        end

        "<TimeTrigger><StartBoundary>#{EPOCH}T00:00:00</StartBoundary>" \
          "<Repetition><Interval>PT#{every / 60}M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition></TimeTrigger>"
      end

      def self.task_xml(description:, arguments:, working_directory:, environment:, log_path:, enabled:, calendar: nil, every: nil)
        triggers = every ? [time_trigger(every)] : calendar.map { |entry| calendar_trigger(entry) }
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <Task version="1.2" xmlns="#{NAMESPACE}">
            <RegistrationInfo>
              <Description>#{Schedule.xml_escape(description)}</Description>
            </RegistrationInfo>
            <Triggers>
              #{triggers.join("\n    ")}
            </Triggers>
            <Principals>
              <Principal id="Author">
                <LogonType>InteractiveToken</LogonType>
                <RunLevel>LeastPrivilege</RunLevel>
              </Principal>
            </Principals>
            <Settings>
              <Enabled>#{enabled}</Enabled>
              <StartWhenAvailable>true</StartWhenAvailable>
              <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
              <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
              <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
              <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
            </Settings>
            <Actions Context="Author">
              <Exec>
                <Command>cmd.exe</Command>
                <Arguments>#{Schedule.xml_escape(command_line(arguments:, environment:, log_path:))}</Arguments>
                <WorkingDirectory>#{Schedule.xml_escape(windows_path(working_directory))}</WorkingDirectory>
              </Exec>
            </Actions>
          </Task>
        XML
      end

      # What runs and when, from a task's XML (as written, or as Task
      # Scheduler gives it back): { arguments:, calendar:, every: }
      def self.parse_task(xml)
        {
          arguments: parse_arguments(Schedule.xml_unescape(xml[%r{<Arguments>(.*?)</Arguments>}m, 1].to_s)),
          calendar:  xml.scan(%r{<CalendarTrigger>(.*?)</CalendarTrigger>}m).flatten.map { |text| parse_calendar_trigger(text) },
          every:     xml[%r{<Interval>(PT[^<]+)</Interval>}, 1]&.then { |duration| parse_duration(duration) }
        }
      end

      def self.parse_calendar_trigger(text)
        hour, minute = text.match(/<StartBoundary>[^<]*T(\d\d):(\d\d)/).captures.map(&:to_i)
        days = text.scan(%r{<(#{DAY_ELEMENTS.join('|')})\s*/>}).flatten.map { |day| DAY_ELEMENTS.index(day) }
        { hour:, minute:, days: days.empty? ? nil : days }
      end

      # "PT1H30M" => 5400. Task Scheduler may normalize the PT90M it was given.
      def self.parse_duration(text)
        hours, minutes, seconds = text.match(/\APT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?\z/).captures.map(&:to_i)
        (hours * 3600) + (minutes * 60) + seconds
      end

      def self.parse_directory(xml) = xml[%r{<WorkingDirectory>(.*?)</WorkingDirectory>}m, 1]&.then { |text| Schedule.xml_unescape(text) }

      # Whether a task's <Settings> leave it enabled; a stopped task is disabled.
      def self.enabled?(xml) = !xml[%r{<Settings>.*?</Settings>}m].to_s.include?("<Enabled>false</Enabled>")

      # "Last Result: 0" from `schtasks /Query /FO LIST /V`; nil until the first run.
      def self.parse_last_result(listing)
        return if listing.match?(%r{^Last Run Time:\s+N/A})

        code = listing[/^Last Result:\s+(-?\d+)/, 1]
        code unless code == NEVER_RAN
      end

      # Every asgard task, from `schtasks /Query /FO CSV /NH`: [[project_slug, name], ...]
      def self.parse_query(csv) = csv.scan(/^"\\asgard\\([^"\\]+)\\([^"\\]+)"/).sort

      # ---- backend API ------------------------------------------------------

      def initialize(project:, root:, home: Dir.home, runner: Schedule.runner, env: ENV)
        @project = project
        @root    = root
        @runner  = runner
        @data    = env["LOCALAPPDATA"] || File.join(home, "AppData", "Local")
      end

      def scheduler = "windows"

      def task(name) = self.class.task_name(@project, name)

      def xml_path(name) = File.join(@data, "asgard", "tasks", "#{file_stem(name)}.xml")

      def log_path(name) = File.join(@data, "asgard", "logs", "#{file_stem(name)}.log")

      def files(spec, asgard:, direnv:) = { xml_path(spec[:name]) => definition(spec, asgard:, direnv:, enabled: true) }

      # A registered task that is disabled was stopped on purpose; keep it so.
      def install(spec, asgard:, direnv:)
        name    = spec[:name]
        stopped = stopped?(name)
        path    = xml_path(name)
        FileUtils.mkdir_p [File.dirname(path), File.dirname(log_path(name))]
        File.write(path, definition(spec, asgard:, direnv:, enabled: !stopped))
        schtasks! "/Create", "/TN", task(name), "/XML", self.class.windows_path(path), "/F"
        stopped ? :stopped : :active
      end

      def uninstall(name)
        schtasks "/Delete", "/TN", task(name), "/F"
        FileUtils.rm_f(xml_path(name))
      end

      def start(name) = schtasks!("/Change", "/TN", task(name), "/ENABLE")

      def stop(name) = schtasks!("/Change", "/TN", task(name), "/DISABLE")

      def trigger(name) = schtasks!("/Run", "/TN", task(name))

      def installed_names
        slug = Schedule.slug(@project)
        installed_entries.filter_map { |project, name| name if project == slug }
      end

      # Every asgard entry on this machine, whatever its project: [[project_slug, name], ...].
      def installed_entries = self.class.parse_query(query("/FO", "CSV", "/NH").to_s)

      # { command:, schedule: } as registered; nil when the task isn't.
      def installed_columns(name) = registered(name)&.then { |xml| Schedule.installed_columns(**self.class.parse_task(xml)) }

      # The project root the task runs in, as registered; nil when it isn't.
      def installed_directory(name) = registered(name)&.then { |xml| self.class.parse_directory(xml) }

      def status(name)
        xml = registered(name)
        return { state: :not_loaded, last_exit: nil } unless xml

        { state: self.class.enabled?(xml) ? :active : :stopped, last_exit: last_result(name) }
      end

      def notes = []

      private

      def file_stem(name) = "asgard.#{Schedule.slug(@project)}.#{name}"

      def definition(spec, asgard:, direnv:, enabled:)
        name, task, args, every = spec.values_at(:name, :task, :args, :every)
        self.class.task_xml(
          description:       "#{Schedule.command_line(task, args)} (#{@project})",
          arguments:         Schedule.program_arguments(task, args, root: @root, asgard:, direnv:),
          working_directory: @root,
          environment:       Schedule.environment(spec),
          log_path:          log_path(name),
          calendar:          every ? nil : Schedule.calendar(at: spec[:at], on: spec[:on]),
          every:,
          enabled:
        )
      end

      # The task's XML as Task Scheduler holds it, or nil when it isn't registered.
      def registered(name) = query("/TN", task(name), "/XML")

      def stopped?(name) = registered(name)&.then { |xml| !self.class.enabled?(xml) } || false

      def last_result(name) = query("/TN", task(name), "/FO", "LIST", "/V")&.then { |listing| self.class.parse_last_result(listing) }

      # `schtasks /Query ...` output, or nil when the query fails (no such task).
      def query(*)
        out, ok = schtasks("/Query", *)
        out if ok
      end

      def schtasks(*) = run("schtasks", *)

      def schtasks!(*args)
        out, ok = schtasks(*args)
        raise Error, "schtasks #{args.join(' ')} failed: #{out.strip}" unless ok

        out
      end

      def run(*argv) = @runner.call(*argv)
    end
  end
end
