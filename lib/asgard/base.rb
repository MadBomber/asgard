# frozen_string_literal: true

require "thor"
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
        subclass.instance_variable_set(:@_deps,              {})
        subclass.instance_variable_set(:@_pending_deps,      [])
        subclass.instance_variable_set(:@_pending_single_desc,      nil)
        subclass.instance_variable_set(:@_pending_single_desc_opts, nil)
        subclass.instance_variable_set(:@_running,    Set.new)
        subclass.instance_variable_set(:@_done,       Set.new)
        subclass.instance_variable_set(:@_cond,       Hash.new { |h, k| h[k] = ConditionVariable.new })
        subclass.instance_variable_set(:@_ran_mutex,  Mutex.new)
      end

      def _deps
        @_deps ||= {}
      end

      def _running
        @_running ||= Set.new
      end

      def _done
        @_done ||= Set.new
      end

      def _cond
        @_cond ||= Hash.new { |h, k| h[k] = ConditionVariable.new }
      end

      def _ran_mutex
        @_ran_mutex ||= Mutex.new
      end

      # Reset execution tracking for a fresh asgard invocation.
      def _reset_ran!
        _ran_mutex.synchronize do
          @_running = Set.new
          @_done    = Set.new
          @_cond    = Hash.new { |h, k| h[k] = ConditionVariable.new }
        end
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

      # Allow single-argument desc: desc "Run the tests"
      # The usage string defaults to the method name when the description is the only arg.
      def desc(usage_or_desc, description = nil, options = {})
        if description.nil? || description.is_a?(Hash)
          options = description if description.is_a?(Hash)
          @_pending_single_desc      = usage_or_desc
          @_pending_single_desc_opts = options
        else
          @_pending_single_desc      = nil
          @_pending_single_desc_opts = nil
          super
        end
      end

      def dotenv(path = ".env")
        require "dotenv"
        Dotenv.load(path) if File.exist?(path)
      end

      def default_task(meth = nil)
        if meth && meth != :none && @_default_task_location
          here = caller_locations(1, 1).first
          warn "asgard: default_task :#{meth} at #{here.path}:#{here.lineno} " \
               "overrides default_task :#{@_default_task_name} set at " \
               "#{@_default_task_location.path}:#{@_default_task_location.lineno}"
        end
        if meth && meth != :none
          @_default_task_location = caller_locations(1, 1).first
          @_default_task_name     = meth
        end
        super
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

      public

      def method_added(method_name)
        if @_pending_single_desc && !no_commands?
          pending_desc = @_pending_single_desc
          pending_opts = @_pending_single_desc_opts || {}
          @_pending_single_desc      = nil
          @_pending_single_desc_opts = nil
          desc(method_name.to_s, pending_desc, pending_opts)
        end

        return super unless @usage

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
      # before executing the target command.
      #
      # Completion-based deduplication: a task is only marked done after its
      # body finishes. Threads that arrive at an already-running shared dep
      # wait on its ConditionVariable rather than proceeding immediately,
      # preventing the race where parallel tasks start before a shared dep
      # has actually completed.
      def invoke_command(command, *args)
        $DEBUG   = true if options[:debug]
        $VERBOSE = true if options[:verbose]
        target = command.name.to_sym
        return unless acquire_run_token(target)

        begin
          run_deps_for(target)
          command.run(self, *args)
        ensure
          signal_done(target)
        end
      end
    end

    private

    def acquire_run_token(target)
      self.class._ran_mutex.synchronize do
        if self.class._done.include?(target)
          false
        elsif self.class._running.include?(target)
          self.class._cond[target].wait(self.class._ran_mutex) until self.class._done.include?(target)
          false
        else
          self.class._running.add(target)
          true
        end
      end
    end

    def run_deps_for(target)
      stages = self.class._deps[target]
      return unless stages&.any?

      groups = Dagwood::DependencyGraph.new(self.class._build_dep_graph(stages)).parallel_order
      groups.each { |group| run_dep_group(group) }
    end

    def run_dep_group(group)
      if group.size > 1
        threads = group.map { |task| Thread.new { run_dep(task) } }
        errors  = []
        threads.each { |t| begin; t.join; rescue => e; errors << e; end }
        if errors.size == 1
          raise errors.first
        elsif errors.any?
          errors.each { |e| warn "asgard: #{e.message}" }
          raise Asgard::Error, "#{errors.size} parallel dependencies failed"
        end
      else
        run_dep(group.first)
      end
    end

    def signal_done(target)
      self.class._ran_mutex.synchronize do
        self.class._done.add(target)
        self.class._cond[target].broadcast
      end
    end

    def run_dep(task)
      command = self.class.all_commands[task.to_s]
      invoke_command(command) if command
    end
  end
end
