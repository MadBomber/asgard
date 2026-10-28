# frozen_string_literal: true

module Asgard
  module Watch
    # `asgard watcher run`: the whole watcher in one foreground process.
    # One Listen listener per watched directory of each declaration pushes
    # batches onto the inbox; the dispatcher routes them to worker Ractors;
    # the reporter writes the log and the entry records. A change to any
    # .loki file re-execs the process so declarations are never stale: the
    # listener only raises a flag, and the main thread shuts down and
    # execs, since a listener cannot stop itself from its own callback
    # thread. INT or TERM stops listening, drops triggers that have not
    # started, waits for running tasks to exit, removes the pidfile and
    # returns; a second INT or TERM ends the running tasks.
    class Daemon
      # What a run is made of: the normalized declarations, the real
      # project root, the State, the Spawn::Context, the names of the
      # tasks the project defines, and the pending-changes file a reload
      # handed this run (State::PENDING_ENV), if any.
      Config = Data.define(:declarations, :root, :state, :context, :tasks, :pending) do
        def initialize(pending: nil, **) = super
      end

      LOKI_DEBOUNCE = 0.5

      # Seconds between the TERM a second stop sends running tasks and the
      # KILL for any still running.
      FORCE_GRACE = 5.0

      attr_reader :inbox, :listeners

      # listen: is the Listen module (loaded only when nothing else is
      # given) or a stand-in; exec: replaces the process on reload; out:
      # is where shutdown progress goes; dispatcher: is the Dispatcher class;
      # validate: answers whether the edited project would run (asgard,
      # root); grace: is FORCE_GRACE.
      def initialize(config, listen: Daemon.listen_module, exec: Kernel.method(:exec), out: $stdout, dispatcher: Dispatcher,
                     validate: Daemon.method(:loki_valid?), grace: FORCE_GRACE)
        @config     = config
        @listen     = listen
        @exec       = exec
        @out        = out
        @inbox      = Queue.new
        @listeners  = []
        @stopping   = false
        @force      = false
        @forced_at  = nil
        @reload     = false
        @reporter   = nil
        @dispatcher = nil
        @dispatcher_class = dispatcher
        @validate         = validate
        @grace            = grace
      end

      class << self
        # Listen, loaded only when a daemon is actually built.
        def listen_module
          require "listen"
          Listen
        end

        # Listen's own list of editor and tool temp files (swap files,
        # .DS_Store, ...), kept when its directory defaults are replaced.
        def editor_ignores
          require "listen/silencer"
          Listen::Silencer::DEFAULT_IGNORED_EXTENSIONS
        end

        # The Listen options for one watched directory of a declaration.
        # ignore! replaces Listen's defaults, which ignore log/ and tmp/
        # under every watched directory, with the declaration's own list
        # (Watch.ignores_for) plus +editor+ (editor_ignores).
        def listen_options(spec, dir, editor: editor_ignores)
          { only: spec[:only][dir], ignore!: [*spec[:ignore][dir], editor], wait_for_delay: spec[:debounce], relative: true }.compact
        end

        # What the main loop does next: a stop wins over a pending reload.
        def next_action(stopping:, reload:)
          return :stop if stopping

          reload ? :reload : :wait
        end

        # Drops the triggers still waiting in a worker's +mailbox+, with
        # any spilled change lists, and queues the nil that ends the worker
        # once its running task exits. The dropped triggers, oldest first.
        def close_queue(mailbox)
          dropped = Dispatcher.take_waiting(mailbox.queue)
          dropped.each { |item| Worker.remove_changes_file(item[:changes_file]) if item.is_a?(Hash) }
          mailbox.push(nil)
          dropped
        end

        # Waits for a worker to end; one that died has nothing to wait for.
        def join_worker(ractor)
          ractor.respond_to?(:join) ? ractor.join : ractor.take
        rescue Ractor::Error
          nil
        end

        # [entry, { modified:, added:, removed: }] pairs as the pending
        # list a reload hands on: one { entry:, changes: } per entry, its
        # changes merged in order.
        def pending(pairs)
          pairs.group_by(&:first).map do |entry, batches|
            { entry:, changes: Watch.merge_changes(batches.map { |_, lists| Changes.new(**lists.slice(*Changes.members)) }).to_h }
          end
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

        # Whether the edited project would run: `asgard watcher check`
        # exits 0 in +root+, which loads the task files and checks the
        # declarations exactly as `watcher run` does (some watch declared,
        # every watched task defined). Its errors go to the daemon's log,
        # so the reason shows.
        def loki_valid?(asgard, root) = system(asgard, "watcher", "check", chdir: root, in: File::NULL, out: File::NULL) || false

        # Runs a clean-up step whose failure must not hide the error that
        # made it necessary.
        def quietly
          yield
        rescue StandardError
          nil
        end

        # The tasks declared by watch but not defined by the project.
        def unknown_tasks(declarations, tasks) = declarations.values.map { |spec| spec[:task] }.uniq - tasks

        # Sends +signal+ to the process group of the task running as +pid+,
        # only when task_group? proves it is one; whether it was sent. The
        # keywords stand in for the system in tests.
        def signal_task(signal, pid, task, own_pgrp: Process.getpgrp, pgid_of: Process.method(:getpgid),
                        command: Pid.method(:command_line), kill: Process.method(:kill))
          return false unless task_group?(pid, task, own_pgrp:, pgid_of:, command:)

          kill.call(signal, -pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end

        # Whether -pid may be signalled as a watched task's group: pid is an
        # Integer above 1 (kill(2) gives a group of 0 or 1, and -1, meanings
        # far beyond one task), neither this daemon nor its group, still the
        # leader of its own group as a task spawned with pgroup: is, and
        # still running asgard +task+ (a pid reused since is not ours).
        def task_group?(pid, task, own_pgrp:, pgid_of:, command:)
          return false unless pid.is_a?(Integer) && pid > 1 && pid != own_pgrp && pid != Process.pid

          pgid_of.call(pid) == pid && State.task_process?(task, command: command.call(pid))
        rescue Errno::ESRCH, Errno::EPERM
          false
        end

        # The signal a forced stop sends next: TERM first, KILL once
        # +grace+ seconds have passed since (+forced_at+), else nil.
        def escalation(forced_at, now, grace)
          return "TERM" unless forced_at

          "KILL" if now - forced_at >= grace
        end

        # Whether +io+ is an open File on +path+: how the daemon knows its
        # output is the watcher log `start` pointed it at.
        def writes_to?(io, path) = io.is_a?(File) && !io.closed? && File.exist?(path) && File.identical?(io, path)

        # Points each of +ios+ at a fresh +path+ (after the log rotated
        # away beneath them), unbuffered.
        def reopen_log(ios, path)
          ios.each do |io|
            io.reopen(path, "a")
            io.sync = true
          end
        end
      end

      # Traps go in first: Listen can take seconds to start on a large
      # tree, and a TERM meanwhile must stop the daemon cleanly, not kill
      # it. A start that fails takes down what it started (abandon).
      def run
        check_tasks!
        Dir.chdir(@config.root)
        state = @config.state.prepare
        @lock = state.lock or raise Error, "another watcher is already running for this project (#{state.lock_path} is held)"
        state.write_declarations(@config.declarations.values)
        trap_signals
        begin
          start_watching(state)
        rescue StandardError
          abandon(state)
          raise
        end
        wait_for_stop_or_good_reload
        finish(state, next_action == :reload)
      end

      # Asks run to stop; the trap handler calls this. A second call, while
      # running tasks are still awaited, asks for them to be ended too.
      def stop
        @force    = true if @stopping
        @stopping = true
      end

      # Asks run to replace the process with a fresh `watcher run` so new
      # declarations take effect, once running tasks have exited. The
      # .loki listener calls this from its own thread, so it only sets a
      # flag.
      def reload = @reload = true

      def next_action = Daemon.next_action(stopping: @stopping, reload: @reload)

      # Waits for a stop, or for a reload into a project that would run. A
      # .loki saved with an error, or one that renames a watched task or
      # drops the last watch, would make the new process abort, so the
      # running declarations go on watching until the next save.
      def wait_for_stop_or_good_reload
        loop do
          sleep 0.2 while next_action == :wait
          return if next_action == :stop || @validate.call(@config.context.asgard, @config.root)

          say "watcher: the task files do not load or declare no runnable watch; keeping the running declarations"
          @reload = false
        end
      end

      private

      # Shuts down, then execs the new daemon or lets go of the lock. A
      # reload keeps listening until its running tasks have exited, and
      # hands what was dropped or heard meanwhile to the next daemon. A
      # stop that arrives while a reload waits wins.
      def finish(state, reloading)
        stop_listening unless reloading
        dropped = shutdown(state)
        stop_listening
        unless next_action == :reload
          say "watcher: stopped"
          return @lock.close
        end

        say "watcher: reloading"
        exec_with_lock(write_pending(state, dropped + heard))
      end

      def stop_listening
        @listeners.each(&:stop)
        @listeners = []
      end

      def start_watching(state)
        start_pipeline(state)
        replay(State.take_pending(@config.pending))
        @listeners = build_listeners + [loki_listener]
        @listeners.each(&:start)
        state.write_pid(Process.pid)
      end

      # Routes what the reloading daemon before this one saw but did not
      # run, for entries that are still declared.
      def replay(pending)
        pending.each do |item|
          name = item[:entry]
          @inbox.push([name, item[:changes]]) if @config.declarations.key?(name)
        end
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
      # in between this daemon and its replacement, and is told where the
      # pending changes are (nil unsets the variable).
      def exec_with_lock(pending)
        fd = @lock.fileno
        @exec.call({ State::LOCK_ENV => fd.to_s, State::PENDING_ENV => pending }, @config.context.asgard, "watcher", "run", fd => fd)
      end

      # Writes the pending list for the next daemon; its path, or nil when
      # nothing is pending.
      def write_pending(state, pairs)
        pending = Daemon.pending(pairs)
        return nil if pending.empty?

        State.write_json(state.pending_path, pending)
        state.pending_path
      end

      def check_tasks!
        unknown = Daemon.unknown_tasks(@config.declarations, @config.tasks)
        raise Error, "watch declares tasks this project does not define: #{unknown.join(', ')}" unless unknown.empty?
      end

      # When `start` pointed the daemon's output at the log, that output
      # follows the log through rotation (and is unbuffered), so the
      # daemon's own messages never land in a rotated-away file.
      def start_pipeline(state)
        log          = state.log_path
        @log_outputs = [@out, $stderr].uniq.select { |io| Daemon.writes_to?(io, log) }
        Daemon.reopen_log(@log_outputs, log)
        # Workers push from their Ractors; the reporter thread pops here, in
        # the main Ractor, which the Mailbox wakes on every push.
        @reports           = Ractor.make_shareable(Mailbox.new(RactorQueue.new(capacity: 1024), Ractor.current))
        @reporter          = Reporter.new(@reports, log:, state:, on_rotate: -> { Daemon.reopen_log(@log_outputs, log) })
        @dispatcher        = @dispatcher_class.new(@config.declarations, @config.context, reports: @reports)
        @reporter_thread   = @reporter.start
        @dispatcher_thread = @dispatcher.start(@inbox)
      end

      def build_listeners = @config.declarations.values.flat_map { |spec| spec[:dirs].map { |dir| listener_for(spec, dir) } }

      # One Listen listener for one directory of a declaration, whose
      # callback pushes [entry name, batch] onto the inbox.
      def listener_for(spec, dir)
        name = spec[:name]
        @listen.to(dir, **Daemon.listen_options(spec, dir)) do |modified, added, removed|
          @inbox.push([name, { modified:, added:, removed: }])
        end
      end

      def loki_listener
        only = Daemon.loki_pattern(@config.root, $LOADED_FEATURES)
        @listen.to(@config.root, only:, ignore: Watch.ignores_for(".", []), wait_for_delay: LOKI_DEBOUNCE, relative: true) { reload }
      end

      def trap_signals
        %w[INT TERM].each { |signal| trap(signal) { stop } }
      end

      # One line of the daemon's own output, written out at once: an exec
      # would otherwise drop what is still buffered.
      def say(line)
        @out.puts line
        @out.flush
      end

      # Upstream first, so nothing is in flight when it returns: the
      # dispatcher done routing (anything heard later stays on the inbox),
      # the triggers no worker has started dropped, each worker ended
      # after its running task exits, and only then the reporter, once
      # every report is written. The dropped triggers as [entry, lists].
      def shutdown(state)
        @inbox.push(nil)
        @dispatcher_thread.join
        workers = @dispatcher.workers.values
        dropped = workers.flat_map { |worker| Daemon.close_queue(worker[:mailbox]) }
        wait_for_workers(workers.map { |worker| worker[:ractor] })
        @reports.push(nil)
        @reporter_thread.join
        state.clear
        dropped.filter_map { |item| [item[:entry], item[:changes]] if item.is_a?(Hash) }
      end

      # The batches pushed onto the inbox after the dispatcher stopped.
      def heard
        batches = []
        batches << @inbox.pop until @inbox.empty?
        batches
      end

      # Says which pids it waits for, once per interval, until every
      # worker has ended, ending the tasks after a second stop (escalate).
      def wait_for_workers(ractors, interval: 1.0)
        waiters = ractors.map { |ractor| Thread.new { Daemon.join_worker(ractor) } }
        say "watcher: INT or TERM again ends the running tasks" if @stopping && !@reporter.running.empty?
        loop do
          pids = @reporter.running
          say "watcher: waiting for pid #{pids.join(', ')}" unless pids.empty?
          break if waiters.all? { |waiter| waiter.join(interval) }

          escalate
        end
      end

      # After a second stop: TERM to every running task's process group,
      # then KILL to any still running once the grace period has passed.
      # Each group is signalled only through Daemon.signal_task.
      def escalate
        return unless @force

        now    = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        signal = Daemon.escalation(@forced_at, now, @grace) or return
        @forced_at ||= now
        say "watcher: killing running tasks (#{signal})"
        @reporter.running_tasks.each { |pid, task| Daemon.signal_task(signal, pid, task) }
      end
    end
  end
end
