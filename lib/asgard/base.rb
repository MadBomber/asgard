# frozen_string_literal: true

require "thor"
require "set"
require "dagwood"

module Asgard
  class Base < Thor
    include Asgard::Shell

    class << self
      def subclasses
        @subclasses ||= []
      end

      def inherited(subclass)
        super
        Asgard::Base.subclasses << subclass
        subclass.instance_variable_set(:@_deps,         {})
        subclass.instance_variable_set(:@_vars,         {})
        subclass.instance_variable_set(:@_pending_deps, [])
        subclass.instance_variable_set(:@_ran_tasks,    Set.new)
        subclass.instance_variable_set(:@_ran_mutex,    Mutex.new)
      end

      def _deps
        @_deps ||= {}
      end

      def _vars
        @_vars ||= {}
      end

      def _ran_tasks
        @_ran_tasks ||= Set.new
      end

      def _ran_mutex
        @_ran_mutex ||= Mutex.new
      end

      # Reset execution tracking for a fresh asgard invocation.
      def _reset_ran!
        _ran_mutex.synchronize { @_ran_tasks = Set.new }
      end

      # Translate stages into a DependencyGraph-compatible hash.
      #
      #   stages: [[:one], [:two, :three], [:four]]
      #   → { one: [], two: [:one], three: [:one], four: [:two, :three] }
      def _build_dep_graph(stages)
        graph = {}
        stages.each_with_index do |stage, i|
          prev_stage = i > 0 ? stages[i - 1] : []
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

      def var(name, value = nil, &block)
        value = block if block_given?
        _vars[name.to_sym] = value
        no_commands do
          define_method(name) do
            v = self.class._vars[name.to_sym]
            v.respond_to?(:call) ? v.call : v
          end
        end
      end

      def import(mod)
        include mod
      end

      def dotenv(path = ".env")
        require "dotenv"
        Dotenv.load(path) if File.exist?(path)
      end

      # Validate the full dep graph for cycles using Dagwood::DependencyGraph.
      def validate_deps!
        return if _deps.empty?

        all_tasks  = all_commands.keys.map(&:to_sym)
        full_graph = all_tasks.each_with_object({}) do |task, hash|
          hash[task] = _deps.fetch(task, []).flatten
        end

        Dagwood::DependencyGraph.new(full_graph).order
      rescue TSort::Cyclic => e
        raise Asgard::CircularDependencyError, e.message
      end

      def method_added(method_name)
        pending = Array(@_pending_deps).dup
        @_pending_deps = []

        return super if pending.empty?
        return super if method_name.to_s.start_with?("_")

        # Each element is a Symbol (sequential) or Array (parallel group).
        _deps[method_name.to_sym] = pending.map { |d| Array(d).map(&:to_sym) }
        super
      end
    end

    no_commands do
      # Dispatch hook: resolves and runs all deps (in parallel where declared)
      # before executing the target command. Thread-safe deduplication via
      # the class-level _ran_tasks set ensures each task runs at most once.
      def invoke_command(command, *args)
        $DEBUG   = true if options[:debug]
        $VERBOSE = true if options[:verbose]
        target = command.name.to_sym

        should_run = self.class._ran_mutex.synchronize do
          next false if self.class._ran_tasks.include?(target)
          self.class._ran_tasks.add(target)
          true
        end
        return unless should_run

        stages = self.class._deps[target]
        if stages&.any?
          graph  = self.class._build_dep_graph(stages)
          groups = Dagwood::DependencyGraph.new(graph).parallel_order

          groups.each do |group|
            if group.size > 1
              threads = group.map { |task| Thread.new { _run_dep(task) } }
              threads.each(&:join)
            else
              _run_dep(group.first)
            end
          end
        end

        command.run(self, *args)
      end

      def _run_dep(task)
        command = self.class.all_commands[task.to_s]
        invoke_command(command) if command
      end
    end
  end
end
