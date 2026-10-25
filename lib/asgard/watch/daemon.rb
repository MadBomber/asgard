# frozen_string_literal: true

module Asgard
  module Watch
    # `asgard watcher run`: the whole watcher in one foreground process.
    # One Listen listener per declaration pushes batches onto the inbox;
    # the dispatcher routes them to worker Ractors; the reporter writes the
    # log and the entry records. A change to any .loki file re-execs the
    # process so declarations are never stale: the listener only raises a
    # flag, and the main thread shuts down and execs, since a listener
    # cannot stop itself from its own callback thread. INT or TERM stops
    # listening, drops triggers that have not started, waits for running
    # tasks to exit, removes the pidfile and returns.
    class Daemon
      # What a run is made of: the normalized declarations, the real
      # project root, the State, the Spawn::Context, and the names of the
      # tasks the project defines.
      Config = Data.define(:declarations, :root, :state, :context, :tasks)

      LOKI_DEBOUNCE = 0.5

      attr_reader :inbox, :listeners

      # listen: is the Listen module (loaded only when nothing else is
      # given) or a stand-in; exec: replaces the process on reload; out:
      # is where shutdown progress goes; dispatcher: is the Dispatcher class;
      # validate: answers whether the edited task files load (asgard, root).
      def initialize(config, listen: Daemon.listen_module, exec: Kernel.method(:exec), out: $stdout, dispatcher: Dispatcher,
                     validate: Daemon.method(:loki_valid?))
        @config     = config
        @listen     = listen
        @exec       = exec
        @out        = out
        @inbox      = Queue.new
        @listeners  = []
        @stopping   = false
        @reload     = false
        @reporter   = nil
        @dispatcher = nil
        @dispatcher_class = dispatcher
        @validate         = validate
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

        # What the main loop does next: a stop wins over a pending reload.
        def next_action(stopping:, reload:)
          return :stop if stopping

          reload ? :reload : :wait
        end

        # Drops the triggers still waiting in a worker's +mailbox+ and
        # queues the nil that ends the worker once its running task exits.
        def close_queue(mailbox)
          queue = mailbox.queue
          queue.try_pop until queue.empty?
          mailbox.push(nil)
        end

        # Waits for a worker to end; one that died has nothing to wait for.
        def join_worker(ractor)
          ractor.respond_to?(:join) ? ractor.join : ractor.take
        rescue Ractor::Error
          nil
        end

        # The paths, relative to +root+, whose change reloads the daemon:
        # every task file in +loaded+ (what $LOADED_FEATURES holds) inside
        # the root, and any .loki directly in the root, where an
        # `import "*.loki"` would find a new one.
        def loki_pattern(root, loaded)
          real  = File.realpath(root.to_s)
          files = loaded.select { |path| path.to_s.end_with?(".loki") }.filter_map { |path| relative_to(real, path) }
          Regexp.union(%r{\A[^/]*\.loki\z}, *files.map { |file| /\A#{Regexp.escape(file)}\z/ })
        end

        # +path+ relative to +root+ (a real path), or nil outside it. Real
        # paths on both sides where the file exists, since a symlinked
        # temp dir (/var -> /private/var) would otherwise never match.
        def relative_to(root, path)
          full = File.exist?(path.to_s) ? File.realpath(path.to_s) : File.expand_path(path.to_s)
          full.delete_prefix("#{root}/") if full.start_with?("#{root}/")
        end

        # Whether the project's task files load: `asgard help` exits 0 in
        # +root+. Its errors go to the daemon's log, so the reason shows.
        def loki_valid?(asgard, root) = system(asgard, "help", chdir: root, in: File::NULL, out: File::NULL) || false

        # Runs a clean-up step whose failure must not hide the error that
        # made it necessary.
        def quietly
          yield
        rescue StandardError
          nil
        end

        # The tasks declared by watch but not defined by the project.
        def unknown_tasks(declarations, tasks) = declarations.values.map { |spec| spec[:task] }.uniq - tasks
      end

      # Traps go in first: Listen can take seconds to start on a large
      # tree, and a TERM meanwhile must stop the daemon cleanly, not kill
      # it. A start that fails takes down what it started (abandon).
      def run
        check_tasks!
        Dir.chdir(@config.root)
        state = @config.state.prepare
        @lock = state.lock or raise Error, "another watcher is already running for this project (#{state.lock_path} is held)"
        trap_signals
        begin
          start_watching(state)
        rescue StandardError
          abandon(state)
          raise
        end
        wait_for_stop_or_good_reload
        reloading = next_action == :reload
        shutdown(state, reloading ? "reloading" : "stopped")
        reloading ? exec_with_lock : @lock.close
      end

      # Asks run to stop; the trap handler calls this.
      def stop = @stopping = true

      # Asks run to replace the process with a fresh `watcher run` so new
      # declarations take effect, once running tasks have exited. The
      # .loki listener calls this from its own thread, so it only sets a
      # flag.
      def reload = @reload = true

      def next_action = Daemon.next_action(stopping: @stopping, reload: @reload)

      # Waits for a stop, or for a reload whose task files load. A .loki
      # saved with an error would make the new process abort, so the
      # running declarations go on watching until the next save.
      def wait_for_stop_or_good_reload
        loop do
          sleep 0.2 while next_action == :wait
          return if next_action == :stop || @validate.call(@config.context.asgard, @config.root)

          @out.puts "watcher: the task files do not load; keeping the running declarations"
          @reload = false
        end
      end

      private

      def start_watching(state)
        start_pipeline(state)
        @listeners = build_listeners + [loki_listener]
        @listeners.each(&:start)
        state.write_pid(Process.pid)
      end

      # After a failed start: stop whatever listens, end the pipeline
      # without waiting on anything, drop the pidfile and the lock.
      def abandon(state)
        @listeners.each { |listener| Daemon.quietly { listener.stop } }
        @inbox.push(nil)
        @dispatcher&.workers&.each_value { |worker| Daemon.close_queue(worker[:mailbox]) }
        @reports&.push(nil)
        state.clear
        @lock.close
      end

      # The new process inherits the held lock, so no other start can slip
      # in between this daemon and its replacement.
      def exec_with_lock
        fd = @lock.fileno
        @exec.call({ State::LOCK_ENV => fd.to_s }, @config.context.asgard, "watcher", "run", fd => fd)
      end

      def check_tasks!
        unknown = Daemon.unknown_tasks(@config.declarations, @config.tasks)
        raise Error, "watch declares tasks this project does not define: #{unknown.join(', ')}" unless unknown.empty?
      end

      def start_pipeline(state)
        # Workers push from their Ractors; the reporter thread pops here, in
        # the main Ractor, which the Mailbox wakes on every push.
        @reports           = Ractor.make_shareable(Mailbox.new(RactorQueue.new(capacity: 1024), Ractor.current))
        @reporter          = Reporter.new(@reports, log: state.log_path, state:)
        @dispatcher        = @dispatcher_class.new(@config.declarations, @config.context, reports: @reports)
        @reporter_thread   = @reporter.start
        @dispatcher_thread = @dispatcher.start(@inbox)
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
        only = Daemon.loki_pattern(@config.root, $LOADED_FEATURES)
        @listen.to(@config.root, only:, ignore: DEFAULT_IGNORES, wait_for_delay: LOKI_DEBOUNCE, relative: true) { reload }
      end

      def trap_signals
        %w[INT TERM].each { |signal| trap(signal) { stop } }
      end

      # Upstream first, so nothing is in flight when it returns: no more
      # batches, the dispatcher done routing, the triggers no worker has
      # started dropped, each worker ended after its running task exits,
      # and only then the reporter, once every report is written.
      def shutdown(state, outcome = "stopped")
        @listeners.each(&:stop)
        @inbox.push(nil)
        @dispatcher_thread.join
        workers = @dispatcher.workers.values
        workers.each { |worker| Daemon.close_queue(worker[:mailbox]) }
        wait_for_workers(workers.map { |worker| worker[:ractor] })
        @reports.push(nil)
        @reporter_thread.join
        state.clear
        @out.puts "watcher: #{outcome}"
      end

      # Says which pids it waits for, once per interval, until every
      # worker has ended.
      def wait_for_workers(ractors, interval: 1.0)
        waiters = ractors.map { |ractor| Thread.new { Daemon.join_worker(ractor) } }
        loop do
          pids = @reporter.running
          @out.puts "watcher: waiting for pid #{pids.join(', ')}" unless pids.empty?
          break if waiters.all? { |waiter| waiter.join(interval) }
        end
      end
    end
  end
end
