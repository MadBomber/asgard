# frozen_string_literal: true

require "pathname"
require "shellwords"
require "time"

# warn is silent when $VERBOSE is nil and bypasses $stderr in Ruby 4.0 (see
# base/task_dsl.rb); these messages are for the user, so they always print.
# rubocop:disable Style/StderrPuts

module Asgard
  module Watch
    # `asgard watcher SUBCOMMAND` — runs and manages the watcher for the
    # entries declared with `watch :task, paths: ...` in a .loki file.
    # Subclasses Asgard::Base rather than Tasks so `asgard watcher help`
    # lists only these subcommands, not every project task.
    class Commands < Asgard::Base
      namespace "watcher"

      HEADERS   = ["NAME", "TASK", "WATCHES", "DAEMON", "LAST RUN"].freeze
      STOP_WAIT = 1.0

      class << self
        # The WATCHES column: the declared paths and, unless every kind of
        # change counts, the kinds that do.
        def describe(spec)
          events = spec[:events].to_a.map(&:to_s)
          kinds  = events.size == EVENTS.size ? "" : " [#{events.join(', ')}]"
          "#{spec[:paths].join(' ')}#{kinds}"
        end

        # The LAST RUN column from an entry's record: never, still running,
        # or its exit status with duration and finish time.
        def last_run(entry)
          return "never" unless entry
          return "running (pid #{entry[:pid]})" unless entry.key?(:finished)

          finished = Time.iso8601(entry[:finished]).strftime("%Y-%m-%d %H:%M:%S")
          "#{entry[:status]} (#{format('%.1fs', entry[:seconds])}, #{finished})"
        end
      end

      desc "tree", "Print a tree of the watcher subcommands", hide: true
      # Redefined only to re-register tree as hidden in this namespace.
      def tree = super # rubocop:disable Lint/UselessMethodDefinition

      no_commands do
        def watches = Watch.declarations

        def watch_root = @watch_root ||= File.realpath((Asgard.find_task_file&.dirname || Pathname.pwd).to_s)

        def watch_project = File.basename(watch_root)

        def state = @state ||= State.new(project: watch_project, root: watch_root)

        def declared_watches
          abort "No watches declared. Add `watch :task, paths: \"lib\"` inside class Tasks in #{watch_root}/.loki." if watches.empty?

          unknown = Daemon.unknown_tasks(watches, Tasks.all_commands.keys)
          abort "watcher: no such task(s): #{unknown.join(', ')}" unless unknown.empty?

          watches
        end

        def watch_direnv
          return unless File.exist?(File.join(watch_root, ".envrc"))

          Schedule.which("direnv", ENV.fetch("PATH", nil)) or
            $stderr.puts "watcher: .envrc found but direnv is not on PATH; its variables will not be loaded"
        end

        def watch_asgard = Schedule.which("asgard", ENV.fetch("PATH", nil)) || abort("watcher: asgard is not on PATH")

        def spawn_context
          Spawn::Context.new(root: watch_root, log: state.log_path, base: Spawn.base_env, asgard: watch_asgard, direnv: watch_direnv)
        end

        def refuse_if_running
          pid = state.running_pid
          abort "watcher is already running for #{watch_project} (pid #{pid}); `asgard watcher stop` first." if pid
        end
      end

      # Thor reserves `run` as a method name, so the command is `daemon`
      # with `run` as its usage and mapped name, as --version is _version.
      desc "run", "Watch in the foreground until INT or TERM (what `start` runs detached)"
      map "run" => :daemon
      def daemon
        specs = declared_watches
        refuse_if_running
        config = Daemon::Config.new(declarations: specs, root: watch_root, state:, context: spawn_context, tasks: Tasks.all_commands.keys)
        Daemon.new(config).run
      end

      desc "start", "Start the watcher for this project in the background"
      def start
        specs = declared_watches
        refuse_if_running
        log = state.log_path
        state.prepare.write_declarations(specs.values)
        pid = Process.spawn(watch_asgard, "watcher", "run", chdir: watch_root, pgroup: true, out: [log, "a"], err: %i[child out])
        Process.detach(pid)
        state.write_pid(pid)
        puts "started watcher for #{watch_project} (pid #{pid}); log: #{log}"
      end

      desc "stop", "Stop the watcher; a task already running finishes first"
      def stop
        pid = state.running_pid or abort("watcher is not running for #{watch_project}.")
        Process.kill("TERM", pid)
        while Reporter.alive?(pid)
          running = state.running_entries.map { |entry| "#{entry[:entry]} (pid #{entry[:pid]})" }
          puts "watcher: waiting for #{running.join(', ')}" unless running.empty?
          sleep STOP_WAIT
        end
        state.clear
        puts "stopped watcher for #{watch_project}"
      end

      no_commands do
        # True when list should cover every project: asked for with --all, or
        # there is no .loki here, so no single project to scope to.
        def list_all? = options[:all] || Asgard.find_task_file.nil?

        def no_watches_message
          return "No watchers have been started on this machine." if list_all?

          "No watches declared for #{watch_project}. Add `watch :task, paths: \"lib\"` inside class Tasks in #{watch_root}/.loki."
        end

        # { title => rows } for every project, or { nil => rows } for this one; empty groups drop out.
        def list_groups
          groups = list_all? ? all_groups : { nil => Commands.project_rows(state, declared_records) }
          groups.reject { |_, rows| rows.empty? }
        end

        def declared_records = watches.values.map { |spec| State.declaration_record(spec) }

        # Every project with watcher state, titled "Project: slug (/root)". This
        # project's rows come from its live declarations; the others' from what
        # `start` recorded, since their .loki files are not loaded.
        def all_groups
          State.all.to_h do |slug, root|
            other = State.new(project: slug, root:)
            own   = Asgard.find_task_file && root == watch_root
            ["Project: #{slug} (#{root})", Commands.project_rows(other, own ? declared_records : other.read_declarations)]
          end
        end
      end

      class << self
        # One `list` row per declaration record, with the project's daemon
        # state and each entry's last run.
        def project_rows(project_state, records)
          daemon  = project_state.running_pid ? "running" : "stopped"
          entries = project_state.entries
          records.map { |record| watch_row(record, daemon, entries[record[:name]]) }
        end

        def watch_row(record, daemon, entry)
          { name: record[:name], command: "asgard #{record[:task]}", schedule: describe(record),
            state: daemon, last_exit: last_run(entry) }
        end
      end

      desc "list", "Show this project's watches, whether the watcher is running, and each entry's last run"
      method_option :all, aliases: "-a", type: :boolean, desc: "List every project's watches, not just this one's"
      def list
        groups = list_groups
        return puts(no_watches_message) if groups.empty?

        puts groups.map { |title, rows| Schedule::Table.draw(rows, title:, headers: HEADERS) }.join("\n\n")
        puts "\nLogs: #{State.base_dir}  (asgard watcher log)"
      end

      desc "preview", "Show the command and environment each watch would run, without running anything"
      def preview
        context = spawn_context
        declared_watches.each_value { |spec| print_preview(spec, context) }
      end

      no_commands do
        def print_preview(spec, context)
          description = Spawn.description(spec, Changes.new, context)
          puts "# #{spec[:name]}: #{Shellwords.join(description[:argv])}  (#{Commands.describe(spec)})"
          description[:env].sort.each { |key, value| puts "#{key}=#{value}" }
          puts
        end
      end

      desc "log", "Print this project's watcher log to STDOUT"
      method_option :follow, aliases: "-f", type: :boolean, desc: "Keep printing new output as it arrives (tail -f)"
      def log
        path = state.log_path
        return $stderr.puts "#{watch_project} has no watcher log yet (#{path}); it is created on the first start." unless File.exist?(path)
        return sh("tail -n +1 -f #{path.shellescape}", silent: true, exec: true) if options[:follow]

        IO.copy_stream(path, $stdout)
      end
    end
  end
end
# rubocop:enable Style/StderrPuts
