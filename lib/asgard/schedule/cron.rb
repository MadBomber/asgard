# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tempfile"

module Asgard
  module Schedule
    # Portable backend for any machine with cron: each declaration becomes a
    # block in the user's crontab, between marker comments,
    #
    #   # asgard:begin <project>.<name>
    #   30 17 * * 1,2,3,4,5 cd /proj && env PATH=... /bin/asgard sync >> log 2>&1
    #   # asgard:end <project>.<name>
    #
    # and everything outside those markers is left alone. A stopped entry
    # keeps its block with the job lines commented out (`#~ `) and
    # "stopped" on the begin marker, so install keeps it stopped. Not
    # selected by default; set ASGARD_SCHEDULER=cron.
    #
    # What cron cannot do: run a job missed while the machine was off,
    # report a job's last exit status, or space every: runs from the last
    # run (it follows the clock, so only whole minutes dividing an hour, or
    # whole hours dividing a day, are accepted).
    # Implements the backend API documented in declaration.rb.
    class Cron
      BEGIN_TAG = "# asgard:begin"
      END_TAG   = "# asgard:end"
      STOPPED   = "#~ "

      # cron has no exit-status record to read back.
      LAST_EXIT = "n/a"

      NOTE = "cron: runs jobs only while the machine is on (missed runs are skipped), and every: follows the clock."

      # ---- pure helpers -----------------------------------------------------

      def self.entry_id(project, name) = "#{id_prefix(project)}#{name}"

      def self.id_prefix(project) = "#{Schedule.slug(project)}."

      # { hour: 17, minute: 30, days: [1, 5] } => "30 17 * * 1,5"
      def self.calendar_fields(entry) = "#{entry[:minute]} #{entry[:hour]} * * #{entry[:days]&.join(',') || '*'}"

      # 300 => "*/5 * * * *", 21600 => "0 */6 * * *". cron's resolution is a
      # minute and its steps restart with each hour/day, so only intervals
      # that divide an hour or a day evenly can be said.
      def self.interval_fields(every)
        minutes, extra = every.divmod(60)
        fields = interval_minutes(minutes) unless extra.positive?
        fields or raise Error, "cron cannot run every #{every}s; use whole minutes that divide an hour or whole hours that divide a day"
      end

      def self.interval_minutes(minutes)
        hours = minutes / 60
        if minutes.positive? && minutes < 60 && (60 % minutes).zero?
          "*/#{minutes} * * * *"
        elsif minutes >= 60 && (minutes % 60).zero? && hours <= 24 && (24 % hours).zero?
          "0 */#{hours} * * *"
        end
      end

      # The five time fields, one String per crontab line the declaration needs.
      def self.schedule_fields(spec)
        every = spec[:every]
        return [interval_fields(every)] if every

        Schedule.calendar(at: spec[:at], on: spec[:on]).map { |entry| calendar_fields(entry) }
      end

      # What cron runs: into the project root, then the job under env, output
      # appended to the log. cron treats an unescaped % as a newline.
      def self.command(arguments:, working_directory:, environment:, log_path:)
        words = Shellwords.join(["env", *environment.map { |key, value| "#{key}=#{value}" }, *arguments])
        "cd #{working_directory.shellescape} && #{words} >> #{log_path.shellescape} 2>&1".gsub("%", "\\%")
      end

      # The marker-wrapped text for one entry.
      def self.block(id, jobs) = wrap(id, "", jobs)

      # The same, marked stopped with its job lines commented out.
      def self.stopped_block(id, jobs) = wrap(id, " stopped", jobs.map { |job| "#{STOPPED}#{job}" })

      def self.wrap(id, mark, lines) = ["#{BEGIN_TAG} #{id}#{mark}", *lines, "#{END_TAG} #{id}"].join("\n") << "\n"

      # { "project.name" => { stopped: false, jobs: ["30 17 * * 1 cd ..."] } } for each asgard block in a crontab.
      def self.parse_blocks(text)
        text.to_s.scan(block_pattern).to_h { |id, stopped, body| [id, { stopped: !stopped.nil?, jobs: job_lines(body) }] }
      end

      def self.job_lines(body) = body.lines.map { |line| line.chomp.delete_prefix(STOPPED) }

      # One entry's block, or any entry's: captures the id, " stopped" and the job lines.
      def self.block_pattern(id = nil)
        id_source = id ? Regexp.escape(id) : '\S+'
        /^#{BEGIN_TAG} (#{id_source})( stopped)?\n(.*?)^#{END_TAG} \1$\n?/m
      end

      # The crontab with +id+'s block replaced in place, or appended when it has none.
      def self.with_block(text, id, block)
        pattern = block_pattern(id)
        return text.sub(pattern) { block } if text.match?(pattern)

        "#{text}#{"\n" unless text.empty? || text.end_with?("\n")}#{block}"
      end

      def self.without_block(text, id) = text.sub(block_pattern(id), "")

      # One job line's what-runs and when:
      # { arguments:, directory:, calendar: [{ hour:, minute:, days: }], every: Integer|nil }
      def self.parse_job(line)
        minute, hour, _, _, days, command = line.split(" ", 6)
        words = Shellwords.split(shell_command(command))
        { arguments: parse_arguments(words), directory: (words[1] if words.first == "cd") }.merge(parse_schedule(minute, hour, days))
      end

      # `cd DIR && env K=V... PROGRAM ARGS... >> LOG 2>&1` => PROGRAM ARGS...
      def self.parse_arguments(words) = (words[4...-3] || []).drop_while { |word| word.match?(/\A\w+=/) }

      def self.parse_schedule(minute, hour, days)
        if minute.start_with?("*/")
          { calendar: [], every: minute.delete_prefix("*/").to_i * 60 }
        elsif hour.start_with?("*/")
          { calendar: [], every: hour.delete_prefix("*/").to_i * 3600 }
        else
          { calendar: [{ hour: hour.to_i, minute: minute.to_i, days: days == "*" ? nil : days.split(",").map(&:to_i) }], every: nil }
        end
      end

      # All of an entry's job lines as one: the program and directory of the
      # first, every time, and the interval if any.
      def self.parse_jobs(jobs)
        parsed = jobs.map { |job| parse_job(job) }
        {
          **parsed.first.slice(:arguments, :directory),
          calendar: parsed.flat_map { |job| job[:calendar] },
          every:    parsed.filter_map { |job| job[:every] }.first
        }
      end

      # The command field of a job line as `sh -c` wants it: cron's \% is a plain %.
      def self.shell_command(command) = command.to_s.gsub("\\%", "%")

      # A parsed block's state for `status`: nil (not in the crontab) => :not_loaded.
      def self.state(entry)
        return :not_loaded unless entry

        entry[:stopped] ? :stopped : :active
      end

      # ---- backend API ------------------------------------------------------

      def initialize(project:, root:, home: Dir.home, runner: Schedule.runner, env: ENV)
        @project = project
        @root    = root
        @runner  = runner
        @state   = env["XDG_STATE_HOME"] || File.join(home, ".local", "state")
      end

      def scheduler = "cron"

      def id(name) = self.class.entry_id(@project, name)

      def log_path(name) = File.join(@state, "asgard", "asgard.#{id(name)}.log")

      # The crontab itself is the one file install writes, shown here as "crontab".
      def files(spec, asgard:, direnv:) = { "crontab" => self.class.block(id(spec[:name]), jobs(spec, asgard:, direnv:)) }

      def install(spec, asgard:, direnv:)
        name     = spec[:name]
        entry_id = id(name)
        klass    = self.class
        lines    = jobs(spec, asgard:, direnv:)
        stopped  = stopped?(name)
        block    = stopped ? klass.stopped_block(entry_id, lines) : klass.block(entry_id, lines)
        FileUtils.mkdir_p File.dirname(log_path(name))
        write_crontab klass.with_block(read_crontab, entry_id, block)
        stopped ? :stopped : :active
      end

      def uninstall(name)
        text     = read_crontab
        entry_id = id(name)
        klass    = self.class
        write_crontab klass.without_block(text, entry_id) if klass.parse_blocks(text).key?(entry_id)
      end

      def start(name) = rewrite(name) { |entry_id, lines| self.class.block(entry_id, lines) }

      def stop(name) = rewrite(name) { |entry_id, lines| self.class.stopped_block(entry_id, lines) }

      # Runs the job in the background, as cron would, with its log as the output.
      def trigger(name)
        found = entry(name) or raise Error, "#{name} is not installed"
        command = self.class.shell_command(found[:jobs].first.split(" ", 6).last)
        run! "sh", "-c", "#{command} < /dev/null &"
      end

      def installed_names
        prefix = self.class.id_prefix(@project)
        ids.select { |entry_id| entry_id.start_with?(prefix) }.map { |entry_id| entry_id.delete_prefix(prefix) }.sort
      end

      # Every asgard entry on this machine, whatever its project: [[project_slug, name], ...].
      def installed_entries = ids.map { |entry_id| entry_id.split(".", 2) }.select { |entry| entry.size == 2 }.sort

      # { command:, schedule: } as installed, read from the crontab; nil when there isn't one.
      def installed_columns(name)
        installed(name)&.then { |job| Schedule.installed_columns(**job.slice(:arguments, :calendar, :every)) }
      end

      # The project root the job runs in, read from the crontab; nil when there isn't one.
      def installed_directory(name) = installed(name)&.fetch(:directory)

      def status(name) = { state: self.class.state(entry(name)), last_exit: LAST_EXIT }

      def notes = [NOTE]

      private

      def jobs(spec, asgard:, direnv:)
        klass   = self.class
        command = klass.command(
          arguments:         Schedule.program_arguments(spec[:task], spec[:args], root: @root, asgard:, direnv:),
          working_directory: @root,
          environment:       Schedule.environment(spec),
          log_path:          log_path(spec[:name])
        )
        klass.schedule_fields(spec).map { |fields| "#{fields} #{command}" }
      end

      def entry(name) = self.class.parse_blocks(read_crontab)[id(name)]

      def ids = self.class.parse_blocks(read_crontab).keys

      def stopped?(name) = entry(name)&.fetch(:stopped) || false

      # The entry's parsed job lines, or nil when it is gone or has none left.
      def installed(name)
        jobs = entry(name)&.fetch(:jobs)
        self.class.parse_jobs(jobs) if jobs && !jobs.empty?
      end

      # Replaces an installed entry's block with what the block gives for its id and job lines.
      def rewrite(name)
        text     = read_crontab
        entry_id = id(name)
        klass    = self.class
        found    = klass.parse_blocks(text)[entry_id] or raise Error, "#{name} is not installed"
        write_crontab klass.with_block(text, entry_id, yield(entry_id, found[:jobs]))
      end

      # An empty crontab is `crontab -l` failing with "no crontab for ..."; any
      # other failure must not read as empty, or the next write would erase the real one.
      def read_crontab
        out, ok = run("crontab", "-l")
        return out if ok
        return "" if out.match?(/no crontab/i)

        raise Error, "crontab -l failed: #{out.strip}"
      end

      def write_crontab(text)
        Tempfile.create(["asgard", ".cron"]) do |file|
          file.write(text)
          file.flush
          run! "crontab", file.path
        end
      end

      def run(*argv) = @runner.call(*argv)

      def run!(*argv)
        out, ok = run(*argv)
        raise Error, "#{argv.join(' ')} failed: #{out.strip}" unless ok

        out
      end
    end
  end
end
