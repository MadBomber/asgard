# frozen_string_literal: true

require_relative "declarations"
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

      # Records one declaration (see Declarations.record). Two different
      # commands whose names derive alike both take hashed names first
      # (see rival_commands?).
      def declare(task, **) = Declarations.record(declarations, place(normalize(task, **)), "schedule")

      # The name a command derives (a normalize result's task and args).
      def plain_name(spec) = command_slug(spec[:task], spec[:args])

      # Whether +spec+ has the plain name its command derives, rather than
      # an as: name or a hashed one.
      def derived_name?(spec) = !spec[:args].empty? && spec[:name] == plain_name(spec)

      # Two declarations of different commands that derive the same plain
      # name: neither may keep it.
      def rival_commands?(one, other)
        derived_name?(one) && derived_name?(other) && one.values_at(:task, :args) != other.values_at(:task, :args)
      end

      def with_hashed_name(spec) = spec.merge(name: hashed_slug(spec[:task], spec[:args]))

      # Whether +spec+'s plain name was already given up by a rival in
      # +declarations+, one now under its hashed name, so +spec+ takes its
      # hashed name too. Whatever order the .loki declares them in, every
      # rival ends up hashed.
      def contested?(spec, declarations)
        derived_name?(spec) && declarations.each_value.any? do |other|
          other == with_hashed_name(other) && rival_commands?(other.merge(name: plain_name(other)), spec)
        end
      end

      private

      # +spec+ under the name it is declared by: hashed when a rival gave
      # up its plain name earlier, or meets it now (the rival then moves to
      # its hashed name too).
      def place(spec)
        return with_hashed_name(spec) if contested?(spec, declarations)

        taken = declarations[spec[:name]]
        return spec unless taken && rival_commands?(taken, spec)

        rename_to_hashed(taken)
        with_hashed_name(spec)
      end

      def rename_to_hashed(spec)
        declarations.delete(spec[:name])
        renamed = with_hashed_name(spec)
        declarations[renamed[:name]] = renamed
      end
    end

    # The class-level `schedule` declaration helper for Tasks.
    module DSL
      def schedule(task, **) = Schedule.declare(task, **)
    end
  end
end
