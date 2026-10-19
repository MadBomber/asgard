# frozen_string_literal: true

module Asgard
  # Runs asgard tasks when watched files change. Declare entries at class
  # level in a .loki file:
  #
  #   class Tasks
  #     watch :lint, paths: "lib/**/*.rb"
  #     watch :test, paths: %w[lib test], only: /\.rb\z/
  #   end
  #
  # then manage the watcher with `asgard watcher run|start|stop|list|...`.
  module Watch
    class << self
      # Declared entries for this run, keyed by entry name.
      def declarations
        @declarations ||= {}
      end

      # Records one declaration. Validation and normalization arrive with
      # the declaration slice; for now the raw settings are stored as given.
      def declare(task, **settings)
        declarations[task] = { task: task, **settings }
      end
    end

    # The class-level `watch` declaration helper for Tasks.
    module DSL
      def watch(task, **) = Watch.declare(task, **)
    end
  end
end
