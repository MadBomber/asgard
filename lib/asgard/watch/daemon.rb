# frozen_string_literal: true

module Asgard
  module Watch
    # `asgard watcher run`: the whole watcher in one foreground process.
    # One Listen listener per declaration pushes batches onto the inbox;
    # the dispatcher routes them to worker Ractors; the reporter writes the
    # log and the entry records. A change to any .loki file re-execs the
    # process so declarations are never stale. INT or TERM stops listening,
    # drops triggers that have not started, waits for running tasks to
    # exit, removes the pidfile and returns.
    class Daemon
      # What a run is made of: the normalized declarations, the real
      # project root, the State, the Spawn::Context, and the names of the
      # tasks the project defines.
      Config = Data.define(:declarations, :root, :state, :context, :tasks)

      LOKI_DEBOUNCE = 0.5

      attr_reader :inbox, :listeners

      # listen: is the Listen module (loaded only when nothing else is
      # given) or a stand-in; exec: replaces the process on reload; out:
      # is where shutdown progress goes.
      def initialize(config, listen: Daemon.listen_module, exec: Kernel.method(:exec), out: $stdout)
        @config     = config
        @listen     = listen
        @exec       = exec
        @out        = out
        @inbox      = Queue.new
        @listeners  = []
        @stopping   = false
        @reporter   = nil
        @dispatcher = nil
      end

      class << self
        # Listen, loaded only when a daemon is actually built.
        def listen_module
          require "listen"
          Listen
        end

        # The Listen options for one declaration.
        def listen_options(spec)
          { only: spec[:only], ignore: spec[:ignore], wait_for_delay: spec[:debounce], relative: true }.compact
        end

        # The tasks declared by watch but not defined by the project.
        def unknown_tasks(declarations, tasks) = declarations.values.map { |spec| spec[:task] }.uniq - tasks
      end

      def run
        check_tasks!
        Dir.chdir(@config.root)
        state = @config.state.prepare
        start_pipeline(state)
        @listeners = build_listeners + [loki_listener]
        @listeners.each(&:start)
        state.write_pid(Process.pid)
        trap_signals
        sleep 0.2 until @stopping
        shutdown(state)
      end

      # Asks run to stop; the trap handler calls this.
      def stop = @stopping = true

      # Stops listening and replaces the process with a fresh `watcher run`
      # so new declarations take effect. Running tasks, in their own
      # process groups, carry on; the new daemon does not know about them.
      def reload
        @listeners.each(&:stop)
        @exec.call(@config.context.asgard, "watcher", "run")
      end

      private

      def check_tasks!
        unknown = Daemon.unknown_tasks(@config.declarations, @config.tasks)
        raise Error, "watch declares tasks this project does not define: #{unknown.join(', ')}" unless unknown.empty?
      end

      def start_pipeline(state)
        reports     = RactorQueue.new(capacity: 1024)
        @reporter   = Reporter.new(reports, log: state.log_path, state:)
        @dispatcher = Dispatcher.new(@config.declarations, @config.context, reports:)
        @reporter.start
        @dispatcher.start(@inbox)
      end

      def build_listeners = @config.declarations.values.map { |spec| listener_for(spec) }

      # One Listen listener whose callback pushes [entry name, batch] onto the inbox.
      def listener_for(spec)
        name = spec[:name]
        @listen.to(*spec[:dirs], **Daemon.listen_options(spec)) do |modified, added, removed|
          @inbox.push([name, { modified:, added:, removed: }])
        end
      end

      def loki_listener
        @listen.to(@config.root, only: /\.loki\z/, ignore: DEFAULT_IGNORES, wait_for_delay: LOKI_DEBOUNCE, relative: true) { reload }
      end

      def trap_signals
        %w[INT TERM].each { |signal| trap(signal) { stop } }
      end

      def shutdown(state)
        @listeners.each(&:stop)
        @inbox.push(nil)
        @dispatcher.workers.each_value do |worker|
          queue = worker[:queue]
          queue.try_pop until queue.empty?
        end
        @reporter.drain(out: @out)
        state.clear
        @out.puts "watcher: stopped"
      end
    end
  end
end
