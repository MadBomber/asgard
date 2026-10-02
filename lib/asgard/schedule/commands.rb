# frozen_string_literal: true

require "pathname"
require "shellwords"

# warn is silent when $VERBOSE is nil and bypasses $stderr in Ruby 4.0 (see
# base/task_dsl.rb); these messages are for the user, so they always print.
# rubocop:disable Style/StderrPuts

module Asgard
  module Schedule
    # `asgard schedule SUBCOMMAND` — installs and manages the entries declared
    # with `schedule :task, ...` in a .loki file. Subclasses Asgard::Base
    # rather than Tasks so `asgard schedule help` lists only these
    # subcommands, not every project task.
    class Commands < Asgard::Base
      namespace "schedule"

      desc "tree", "Print a tree of the schedule subcommands", hide: true
      # Redefined only to re-register tree as hidden in this namespace.
      def tree = super # rubocop:disable Lint/UselessMethodDefinition

      no_commands do
        def schedules = Schedule.declarations

        def schedule_root = (Asgard.find_task_file&.dirname || Pathname.pwd).to_s

        def schedule_project = File.basename(schedule_root)

        def scheduler
          @scheduler ||= Schedule.backend_class.new(project: schedule_project, root: schedule_root)
        end

        def declared_schedules
          if schedules.empty?
            abort "No schedules declared. Add `schedule :task, at: \"HH:MM\"` inside class Tasks in #{schedule_root}/.loki."
          end

          specs   = schedules.values
          unknown = specs.map { |spec| spec[:task] }.uniq - Tasks.all_commands.keys
          abort "schedule: no such task(s): #{unknown.join(', ')}" unless unknown.empty?

          specs
        end

        def schedule_direnv
          return unless File.exist?(File.join(schedule_root, ".envrc"))

          Schedule.which("direnv", ENV.fetch("PATH", nil)) or
            $stderr.puts "schedule: .envrc found but direnv is not on PATH; its variables will not be loaded"
        end

        def schedule_asgard = Schedule.which("asgard", ENV.fetch("PATH", nil)) || abort("schedule: asgard is not on PATH")

        def schedule_summary(spec) = "#{Schedule.command_line(spec[:task], spec[:args])} (#{Schedule.describe(**spec)})"

        # One `list` row for this project: its declaration (if still declared) plus live state.
        def schedule_row(name)
          { name:, **Schedule.declared_columns(schedules[name], "no longer declared"), **Schedule.live_columns(scheduler, name) }
        end

        def schedule_install(spec, asgard:, direnv:)
          name  = spec[:name]
          state = scheduler.install(spec, asgard:, direnv:)
          note  = state == :stopped ? " [stopped; `asgard schedule start #{name}` to resume]" : ""
          puts "installed #{name}: #{schedule_summary(spec)}#{note}"
        end

        def schedule_uninstall(name)
          scheduler.uninstall(name)
          puts "removed #{name}"
        end
      end

      desc "preview", "Show the job files install would write, without installing them"
      def preview
        asgard = Schedule.which("asgard", ENV.fetch("PATH", nil)) || "asgard"
        direnv = schedule_direnv
        declared_schedules.each do |spec|
          scheduler.files(spec, asgard:, direnv:).each do |path, content|
            puts "# #{path}: #{schedule_summary(spec)}"
            puts content
          end
        end
      end

      desc "install", "Install this project's schedule declarations (removes undeclared ones)"
      def install
        specs  = declared_schedules
        asgard = schedule_asgard
        direnv = schedule_direnv

        (scheduler.installed_names - specs.map { |spec| spec[:name] }).each { |name| schedule_uninstall(name) }
        specs.each { |spec| schedule_install(spec, asgard:, direnv:) }
        scheduler.notes.each { |note| $stderr.puts note }
      end

      no_commands do
        # [backend, entry name] for an installed entry of this or any project: a
        # bare name, or project/name when several projects use the same one. nil if none.
        def find_installed(name)
          return [scheduler, name] if scheduler.installed_names.include?(name)

          project, entry = name.include?("/") ? name.split("/", 2) : [nil, name]
          matches = scheduler.installed_entries.select { |slug, found| found == entry && (project.nil? || slug == project) }
          abort "#{name} is in several projects (#{matches.map(&:first).join(', ')}); name one as project/#{entry}." if matches.size > 1

          matches.first&.then { |slug, found| [backend_for(slug), found] }
        end

        def resolve_installed(name) = find_installed(name) || abort("#{name} is not installed (see `asgard schedule list --all`).")

        # Like resolve_installed, but a declared entry of this project counts even before it is installed.
        def resolve_known(name)
          return [scheduler, name] if schedules.key?(name)

          find_installed(name) || abort("#{name} is neither declared nor installed (see `asgard schedule list --all`).")
        end

        # True when list should cover every project: asked for with --all, or
        # there is no .loki here, so no single project to scope to.
        def list_all? = options[:all] || Asgard.find_task_file.nil?

        # What `list` says when there is nothing to show; a project-scoped list
        # also tells the user how to look further.
        def no_schedules_message
          backend = scheduler.scheduler
          return "No scheduled tasks installed (#{backend})." if list_all?

          "No scheduled tasks installed for #{schedule_project} (#{backend}).\n" \
            "Use `asgard schedule list --all` to see all currently scheduled tasks."
        end

        # The rows to list, grouped under a project title: { "Project: name (/path)" => [row, ...] }
        # for every project, or { nil => [row, ...] } for this one. Empty groups drop out.
        def list_groups
          groups = list_all? ? all_schedule_groups : { nil => scheduler.installed_names.map { |name| schedule_row(name) } }
          groups.reject { |_, rows| rows.empty? }
        end

        # Every installed entry on the machine, grouped by project.
        def all_schedule_groups
          by_project = scheduler.installed_entries.group_by(&:first)
          by_project.to_h { |slug, entries| [project_title(slug, entries.first.last), entry_rows(entries)] }
        end

        # "Project: slug (/full/path)", the path read from one of the project's job files.
        def project_title(slug, name)
          dir = slug == current_slug ? schedule_root : backend_for(slug).installed_directory(name)
          ["Project: #{slug}", ("(#{dir})" if dir)].compact.join(" ")
        end

        def current_slug = Asgard.find_task_file && Schedule.slug(schedule_project)

        def backend_for(slug) = Schedule.backend_class.new(project: slug, root: schedule_root)

        def entry_rows(entries) = entries.map { |slug, name| entry_row(slug, name) }

        # This project's entries keep their declaration columns; see other_project_row.
        def entry_row(slug, name)
          return schedule_row(name) if slug == current_slug

          other_project_row(slug, name)
        end

        # A row for an entry of another project: its .loki isn't loaded, so the
        # command and schedule are read back from the installed job files.
        def other_project_row(slug, name)
          backend = backend_for(slug)
          shown   = backend.installed_columns(name) || Schedule.declared_columns(nil, "(unreadable)")
          { name:, **shown, **Schedule.live_columns(backend, name) }
        end
      end

      desc "list", "Show this project's installed entries, their state, and last exit status"
      method_option :all, aliases: "-a", type: :boolean, desc: "List every project's entries, not just this one's"
      def list
        groups = list_groups
        return puts(no_schedules_message) if groups.empty?

        puts groups.map { |title, rows| Schedule::Table.draw(rows, title:) }.join("\n\n")
        puts "\nLogs: #{File.dirname(scheduler.log_path(groups.values.first.first[:name]))}  (asgard schedule log NAME)"
      end

      desc "stop NAME", "Stop one scheduled entry; it stays stopped across reboots and installs until started"
      def stop(name)
        backend, entry = resolve_installed(name)
        backend.stop(entry)
        puts "stopped #{name}"
      end

      desc "start NAME", "Start a stopped entry, or install and start just this declared entry"
      def start(name)
        backend, entry = resolve_known(name)
        own  = backend.equal?(scheduler)
        spec = schedules[entry] if own

        if spec
          declared_schedules # validates the task exists
          scheduler.install(spec, asgard: schedule_asgard, direnv: schedule_direnv) # refresh the job files
        else
          why = own ? "is no longer declared" : "belongs to another project"
          $stderr.puts "schedule: #{name} #{why}; starting its installed job as-is"
        end
        backend.start(entry)
        puts "started #{name}"
      end

      desc "trigger NAME", "Run an installed entry now, under the scheduler's environment"
      def trigger(name)
        backend, entry = resolve_installed(name)
        abort "#{name} is stopped; `asgard schedule start #{name}` first." if backend.status(entry)[:state] == :stopped

        backend.trigger(entry)
        puts "triggered #{name}; output goes to #{backend.log_path(entry)}"
      end

      desc "log NAME", "Print the named entry's log file to STDOUT"
      method_option :follow, aliases: "-f", type: :boolean, desc: "Keep printing new output as it arrives (tail -f)"
      def log(name)
        backend, entry = resolve_known(name)

        path = backend.log_path(entry)
        return $stderr.puts "#{name} has no log yet (#{path}); it is created on the first run." unless File.exist?(path)
        return sh("tail -n +1 -f #{path.shellescape}", silent: true, exec: true) if options[:follow]

        IO.copy_stream(path, $stdout)
      end

      desc "remove", "Remove all of this project's installed entries"
      def remove
        names = scheduler.installed_names
        return puts "No scheduled tasks installed for #{schedule_project}." if names.empty?

        names.each { |name| schedule_uninstall(name) }
      end
    end
  end
end
# rubocop:enable Style/StderrPuts
