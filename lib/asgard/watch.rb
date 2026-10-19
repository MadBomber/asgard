# frozen_string_literal: true

require_relative "watch/declaration"
require_relative "watch/changes"
require_relative "watch/spawn"
require_relative "watch/worker"
require_relative "watch/reporter"
require_relative "watch/dispatcher"

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

      # Records one declaration. Redeclaring an identical entry is a no-op
      # (a .loki file loaded twice); a different entry under the same name
      # is an error.
      def declare(task, **settings)
        spec  = normalize(task, **settings)
        name  = spec[:name]
        taken = declarations[name]
        raise ArgumentError, "watch: #{name.inspect} is already declared; give one a distinct as: name" if taken && taken != spec

        declarations[name] = spec
      end
    end

    # The class-level `watch` declaration helper for Tasks.
    module DSL
      def watch(task, **) = Watch.declare(task, **)
    end
  end
end
