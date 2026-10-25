# frozen_string_literal: true

module Asgard
  module Watch
    # Runs one task's triggers, one at a time, in the order they arrive on
    # its queue. One worker exists per distinct task, each in its own
    # Ractor, so different tasks run concurrently while a task never
    # overlaps itself: the wait for the child is the mutex. A worker sees
    # nothing but frozen spawn descriptions and pushes a frozen report on
    # every spawn and every exit; it writes no files itself.
    class Worker
      # Starts and reaps a task from a spawn description. Kept apart from
      # the loop so tests can stand in a recorder.
      module Spawner
        module_function

        # The child's pid. The task runs in the project root with exactly
        # the description's environment, in its own process group, with
        # its output appended to the log.
        def spawn(description) = Process.spawn(description[:env], *description[:argv], **spawn_options(description))

        # stdin is /dev/null: the task's group is a background group on any
        # terminal the daemon has, where a read would stop it with SIGTTIN
        # and leave its worker waiting forever.
        def spawn_options(description)
          { chdir: description[:root], pgroup: true, unsetenv_others: true, in: File::NULL,
            out: [description[:log], "a"], err: %i[child out] }
        end

        # Blocks until the child exits; its exit code.
        def wait(pid)
          _, status = Process.wait2(pid)
          exit_code(status)
        end

        # A signalled child reports 128 + the signal number, as shells do.
        def exit_code(status) = Shell.exit_code(status)
      end

      # The worker loop in its own Ractor. The Ractor is handed its queue,
      # the reports and the spawner (all shareable) and nothing else, and
      # pops through a Mailbox so it sleeps while idle: whoever pushes onto
      # +queue+ must wake it, through Mailbox.new(queue, the_ractor).
      def self.start(queue, reports, spawner: Spawner)
        Ractor.new(queue, reports, spawner) do |inbox, outbox, runner|
          Asgard::Watch::Worker.new(Asgard::Watch::Mailbox.new(inbox, Ractor.current), outbox, spawner: runner).run
        end
      end

      def initialize(queue, reports, spawner: Spawner, clock: Process)
        @queue   = queue
        @reports = reports
        @spawner = spawner
        @clock   = clock
      end

      # Pops descriptions and runs each to completion. A nil on the queue
      # ends the loop.
      def run
        while (description = @queue.pop)
          run_one(description)
        end
      end

      # One trigger. A spawn that fails (the root or the executable gone,
      # an environment too large) is reported as an exit with no pid, so
      # the worker carries on with the next trigger instead of ending.
      def run_one(description)
        entry, task = description.values_at(:entry, :task)
        pid = spawn_or_report(description) or return
        started_at, started = stamp
        report(kind: :spawn, entry:, task:, pid:, at: started_at, changes: description[:changes])
        status = @spawner.wait(pid)
        finished_at, finished = stamp
        report(kind: :exit, entry:, task:, pid:, at: finished_at, status:, seconds: finished - started)
      ensure
        Worker.remove_changes_file(description[:changes_file])
      end

      # The exit code a spawn failure reports, as a shell would: 127 when
      # something was not found, 126 when it could not be run.
      def self.spawn_failure_status(error) = error.is_a?(Errno::ENOENT) ? 127 : 126

      # The task has exited, so the change lists spilled for it are done.
      def self.remove_changes_file(path)
        File.delete(path) if path
      rescue Errno::ENOENT
        nil
      end

      private

      def spawn_or_report(description)
        @spawner.spawn(description)
      rescue SystemCallError => e
        at, = stamp
        report(kind: :exit, entry: description[:entry], task: description[:task], pid: nil, at:,
               status: Worker.spawn_failure_status(e), seconds: 0.0, error: e.message)
        nil
      end

      # [wall-clock seconds since the epoch, monotonic seconds]
      def stamp = [@clock.clock_gettime(Process::CLOCK_REALTIME), @clock.clock_gettime(Process::CLOCK_MONOTONIC)]

      def report(**fields) = @reports.push(Ractor.make_shareable(fields))
    end
  end
end
