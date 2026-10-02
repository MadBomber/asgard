# frozen_string_literal: true

require_relative "schedule/declaration"
require_relative "schedule/launchd"
require_relative "schedule/systemd"
require_relative "schedule/table"
require_relative "schedule/commands"

module Asgard
  # Runs asgard tasks periodically under the platform's own scheduler.
  # Declare entries at class level in a .loki file:
  #
  #   class Tasks
  #     schedule :daily_summary, at: "17:30", on: :weekdays
  #     schedule :sync,          every: 3600
  #     schedule :report, options: "--period week", at: "16:00", on: :friday
  #   end
  #
  # then manage them with `asgard schedule install|list|start|stop|...`.
  module Schedule
    class << self
      # Declared entries for this run, keyed by entry name.
      def declarations
        @declarations ||= {}
      end

      # Records one declaration. Redeclaring an identical entry is a no-op
      # (a .loki file loaded twice); a different entry under the same name
      # is an error.
      def declare(task, **settings)
        spec  = normalize(task, **settings)
        name  = spec[:name]
        taken = declarations[name]
        raise ArgumentError, "schedule: #{name.inspect} is already declared; give one a distinct as: name" if taken && taken != spec

        declarations[name] = spec
      end
    end

    # The class-level `schedule` declaration helper for Tasks.
    module DSL
      def schedule(task, **) = Schedule.declare(task, **)
    end
  end
end
