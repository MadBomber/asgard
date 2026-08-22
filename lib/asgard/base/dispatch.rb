# frozen_string_literal: true

module Asgard
  class Base < Thor
    # Task execution engine: resolves and runs declared dependencies (in
    # parallel where declared) before the target command runs.
    #
    # Completion-based deduplication: a task is only marked done after its
    # body finishes. Threads that arrive at an already-running shared dep
    # wait on its ConditionVariable rather than proceeding immediately,
    # preventing the race where parallel tasks start before a shared dep
    # has actually completed.
    module Dispatch
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def _running
          @_running ||= Set.new
        end

        def _done
          @_done ||= Set.new
        end

        def _cond
          @_cond ||= Hash.new { |h, k| h[k] = ConditionVariable.new }
        end

        # Completed tasks' return values, keyed by task name — lets a task
        # already run by one thread hand its result to another thread that
        # shares the dependency, without either touching `self`.
        def _results
          @_results ||= {}
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
            @_results = {}
          end
        end
      end

      # Dispatch hook: resolves and runs all deps (in parallel where declared)
      # before executing the target command.
      def invoke_command(command, *)
        $DEBUG   = true if options[:debug]
        $VERBOSE = true if options[:verbose]
        target = command.name.to_sym
        return cached_result(target) unless acquire_run_token(target)

        result = nil
        begin
          resolved_deps = run_deps_for(target)
          result = with_dep_results(resolved_deps) { command.run(self, *) }
        ensure
          signal_done(target, result)
        end
        result
      end

      # The results of +target+'s direct dependencies, keyed by task name —
      # available to a task body while it runs, e.g. `dep_result(:test_check)`.
      def dep_results
        Thread.current[:asgard_dep_results] || {}
      end

      def dep_result(task)
        dep_results[task.to_sym]
      end

      private

      def with_dep_results(results)
        thread   = Thread.current
        previous = thread[:asgard_dep_results]
        thread[:asgard_dep_results] = results
        yield
      ensure
        thread[:asgard_dep_results] = previous
      end

      def cached_result(target)
        klass = self.class
        klass._ran_mutex.synchronize { klass._results[target] }
      end

      def acquire_run_token(target)
        klass   = self.class
        mutex   = klass._ran_mutex
        done    = klass._done
        running = klass._running

        mutex.synchronize do
          if done.include?(target)
            false
          elsif running.include?(target)
            klass._cond[target].wait(mutex) until done.include?(target)
            false
          else
            running.add(target)
            true
          end
        end
      end

      def run_deps_for(target)
        stages = self.class._deps[target]
        return {} unless stages&.any?

        stages.each_with_object({}) { |group, acc| acc.merge!(run_dep_group(group)) }
      end

      def run_dep_group(group)
        return { group.first => run_dep(group.first) } unless group.size > 1

        threads = group.map { |task| [task, Thread.new { run_dep(task) }] }
        errors  = []
        results = {}
        threads.each do |task, t|
          results[task] = t.value
        rescue => e
          errors << e
        end

        if errors.size == 1
          raise errors.first
        elsif errors.any?
          errors.each { |e| warn "asgard: #{e.message}" }
          raise Asgard::Error, "#{errors.size} parallel dependencies failed"
        end

        results
      end

      def signal_done(target, result)
        klass = self.class
        klass._ran_mutex.synchronize do
          klass._done.add(target)
          klass._results[target] = result
          klass._cond[target].broadcast
        end
      end

      def run_dep(task)
        command = self.class.all_commands[task.to_s]
        invoke_command(command) if command
      end
    end
  end
end
