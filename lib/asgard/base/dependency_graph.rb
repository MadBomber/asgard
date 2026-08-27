# frozen_string_literal: true

module Asgard
  class Base < Thor
    # Dependency declaration (`depends_on`) and full-graph validation
    # (`validate_deps!`), backed by stdlib TSort for cycle detection.
    module DependencyGraph
      def _deps
        @_deps ||= {}
      end

      # Declare dependencies for the next task.
      # Bare symbols run sequentially; arrays within the splat run in parallel.
      #
      #   depends_on :build                          # sequential
      #   depends_on :build, :lint                   # both sequential
      #   depends_on [:build, :lint]                 # build and lint in parallel
      #   depends_on :setup, [:build, :lint], :test  # setup, then build+lint, then test
      #
      # A sole Proc/lambda defers resolution to validate_deps! (after every
      # .loki file has loaded), instead of now. It must return the same shape
      # the splat form above would: an array of stages, each a Symbol
      # (sequential) or Array (parallel group).
      #
      #   depends_on -> { [all_commands.keys.grep(/_check\z/).map(&:to_sym)] }
      def depends_on(*tasks)
        @_pending_deps = tasks
      end

      # Validate the full dep graph for cycles using stdlib TSort.
      def validate_deps!
        _check_orphaned_deps!
        return if _deps.empty?

        _resolve_lazy_deps!
        all_task_names = all_commands.keys.map(&:to_sym)
        _check_undefined_deps!(all_task_names)
        _check_dep_arities!
        _build_and_sort_graph(all_task_names)
      rescue TSort::Cyclic => e
        raise Asgard::CircularDependencyError, e.message
      end

      private

      # Normalizes depends_on's raw splat args into a _deps-ready value: the
      # sole Proc/lambda unresolved (see #depends_on), or a concrete stage
      # array.
      def _normalize_pending_deps(pending)
        sole = pending.first
        return sole if pending.size == 1 && sole.respond_to?(:call)

        _stages_from(pending)
      end

      # Each element is a Symbol (sequential) or Array (parallel group).
      def _stages_from(list)
        list.map { |d| Array(d).map(&:to_sym) }
      end

      # Replaces any Proc-valued _deps entry (see #depends_on) with its
      # resolved stage array. Runs once, after the full .loki chain has
      # loaded, so the Proc can safely reference tasks defined in any file.
      def _resolve_lazy_deps!
        _deps.each do |task, stages_or_proc|
          next unless stages_or_proc.respond_to?(:call)

          _deps[task] = _stages_from(Array(_call_dep_proc(task, stages_or_proc)))
        end
      end

      def _call_dep_proc(task, dep_proc)
        dep_proc.call
      rescue StandardError => e
        raise Asgard::Error, "depends_on proc for '#{task}' raised #{e.class}: #{e.message}"
      end

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

      # Runs a full topological sort purely to raise TSort::Cyclic on a cycle;
      # the order itself isn't otherwise used (execution order comes from the
      # stage groups each task's own depends_on declared).
      def _build_and_sort_graph(all_task_names)
        full_graph = all_task_names.to_h { |task| [task, _deps.fetch(task) { [] }.flatten] }
        Graph.new(full_graph).tsort
      end

      # Minimal TSort-able wrapper around a task => dependency-list Hash.
      Graph = Struct.new(:edges) do
        include TSort

        def tsort_each_node(&) = edges.each_key(&)
        def tsort_each_child(node, &) = edges.fetch(node).each(&)
      end
      private_constant :Graph
    end
  end
end
