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

        def require_installed!(name)
          abort "#{name} is not installed (see `asgard schedule list`)." unless scheduler.installed_names.include?(name)
        end

        def require_known!(name)
          return if schedules.key?(name) || scheduler.installed_names.include?(name)

          abort "#{name} is neither declared nor installed (see `asgard schedule list`)."
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

      desc "list", "Show this project's installed entries, their state, and last exit status"
      def list
        names = scheduler.installed_names
        return puts "No scheduled tasks installed for #{schedule_project} (#{scheduler.scheduler})." if names.empty?

        names.each do |name|
          status = scheduler.status(name)
          state  = case status[:state]
                   when :active  then "active; last exit: #{status[:last_exit] || 'never run'}"
                   when :stopped then "stopped"
                   else "not loaded"
                   end
          spec   = schedules[name]
          timing = spec ? schedule_summary(spec) : "no longer declared"
          puts "#{name}  #{timing}  [#{state}]  log: #{scheduler.log_path(name)}"
        end
      end

      desc "stop NAME", "Stop one scheduled entry; it stays stopped across reboots and installs until started"
      def stop(name)
        require_installed!(name)
        scheduler.stop(name)
        puts "stopped #{name}"
      end

      desc "start NAME", "Start a stopped entry, or install and start just this declared entry"
      def start(name)
        require_known!(name)
        spec = schedules[name]

        if spec
          declared_schedules # validates the task exists
          scheduler.install(spec, asgard: schedule_asgard, direnv: schedule_direnv) # refresh the job files
        else
          $stderr.puts "schedule: #{name} is no longer declared; starting its installed job as-is"
        end
        scheduler.start(name)
        puts "started #{name}"
      end

      desc "trigger NAME", "Run an installed entry now, under the scheduler's environment"
      def trigger(name)
        require_installed!(name)
        abort "#{name} is stopped; `asgard schedule start #{name}` first." if scheduler.status(name)[:state] == :stopped

        scheduler.trigger(name)
        puts "triggered #{name}; output goes to #{scheduler.log_path(name)}"
      end

      desc "log NAME", "Print the named entry's log file to STDOUT"
      method_option :follow, aliases: "-f", type: :boolean, desc: "Keep printing new output as it arrives (tail -f)"
      def log(name)
        require_known!(name)

        path = scheduler.log_path(name)
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
