# frozen_string_literal: true

module Asgard
  class Base < Thor
    # Dependency declaration (`depends_on`) and full-graph validation
    # (`validate_deps!`), backed by Dagwood for topological sort and cycle
    # detection.
    module DependencyGraph
      def _deps
        @_deps ||= {}
      end

      # Translate stages into a DependencyGraph-compatible hash.
      #
      #   stages: [[:one], [:two, :three], [:four]]
      #   → { one: [], two: [:one], three: [:one], four: [:two, :three] }
      def _build_dep_graph(stages)
        graph = {}
        stages.each_with_index do |stage, i|
          prev_stage = i.positive? ? stages[i - 1] : []
          stage.each { |task| graph[task] = prev_stage.dup }
        end
        graph
      end

      # Declare dependencies for the next task.
      # Bare symbols run sequentially; arrays within the splat run in parallel.
      #
      #   depends_on :build                          # sequential
      #   depends_on :build, :lint                   # both sequential
      #   depends_on [:build, :lint]                 # build and lint in parallel
      #   depends_on :setup, [:build, :lint], :test  # setup, then build+lint, then test
      def depends_on(*tasks)
        @_pending_deps = tasks
      end

      # Validate the full dep graph for cycles using Dagwood::DependencyGraph.
      def validate_deps!
        _check_orphaned_deps!
        return if _deps.empty?

        all_task_names = all_commands.keys.map(&:to_sym)
        _check_undefined_deps!(all_task_names)
        _check_dep_arities!
        _build_and_sort_graph(all_task_names)
      rescue TSort::Cyclic => e
        raise Asgard::CircularDependencyError, e.message
      end

      private

      def _check_orphaned_deps!
        pending = Array(@_pending_deps)
        return unless pending.any?

        raise Asgard::Error,
              "depends_on(#{pending.join(', ')}) declared without a following task definition"
      end

      def _check_undefined_deps!(all_task_names)
        undefined = _deps.values.flatten.uniq - all_task_names
        return unless undefined.any?

        raise Asgard::Error, "undefined task(s) in depends_on: #{undefined.sort.join(', ')}"
      end

      def _check_dep_arities!
        _deps.each_value do |stages|
          stages.flatten.each do |dep|
            meth = instance_method(dep.to_s)
            required = meth.parameters.count { |type, _| type == :req }
            next unless required.positive?

            raise Asgard::Error,
                  "task '#{dep}' has #{required} required argument(s) and cannot be used as a dependency"
          end
        end
      end

      def _build_and_sort_graph(all_task_names)
        full_graph = all_task_names.to_h { |task| [task, _deps.fetch(task, []).flatten] }
        Dagwood::DependencyGraph.new(full_graph).order
      end
    end
  end
end
