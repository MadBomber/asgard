# frozen_string_literal: true

require_relative "schedule"

# Tasks is the single conventional entry point for all .loki files.
# It is pre-defined by the gem so .loki files never need to declare a class.
# Auxiliary *.loki files define modules which are imported into Tasks.
class Tasks < Asgard::Base
  header "\nasgard v#{Asgard::VERSION} The Mighty Thor and Loki working for you"

  footer <<~FOOT
    \nDocumentation ... https://madbomber.github.io/asgard
    Github Repo ..... https://github.com/MadBomber/asgard\n
  FOOT

  class_option :debug,
               type:    :boolean,
               default: false,
               desc:    "Enable debug mode ($DEBUG = true)"

  class_option :verbose,
               type:    :boolean,
               default: false,
               desc:    "Enable verbose output ($VERBOSE = true)"

  class_option :version,
               type:    :boolean,
               default: false,
               desc:    "Show asgard version and exit"
  no_negate :version

  class_option :doctor,
               type:    :boolean,
               default: false,
               desc:    "Diagnose .loki resolution, imports, and task definitions for the CWD, then exit"
  no_negate :doctor

  # Class-level `schedule :task, at: "HH:MM"` declarations (see Asgard::Schedule).
  extend Asgard::Schedule::DSL

  # Gem-owned, so the command is _schedule; the map keeps `asgard schedule`
  # as the name users type, and ancestor_name keeps it in subcommand help.
  desc "schedule SUBCOMMAND", "Manage schedules declared with `schedule :task, ...` (launchd on macOS, systemd on Linux)"
  subcommand "_schedule", Asgard::Schedule::Commands
  map "schedule" => :_schedule
  Asgard::Schedule::Commands.commands.each_value { |command| command.ancestor_name = "schedule" }
end
