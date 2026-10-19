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
        def spawn(description)
          Process.spawn(description[:env], *description[:argv],
                        chdir: description[:root], pgroup: true, unsetenv_others: true,
                        out: [description[:log], "a"], err: %i[child out])
        end

        # Blocks until the child exits; its exit code.
        def wait(pid)
          _, status = Process.wait2(pid)
          exit_code(status)
        end

        # A signalled child reports 128 + the signal number, as shells do.
        def exit_code(status) = status.exitstatus || (128 + status.termsig)
      end

      # The worker loop in its own Ractor. The Ractor is handed the two
      # queues and the spawner (all shareable) and nothing else.
      def self.start(queue, reports, spawner: Spawner)
        Ractor.new(queue, reports, spawner) { |inbox, outbox, runner| Asgard::Watch::Worker.new(inbox, outbox, spawner: runner).run }
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

      def run_one(description)
        entry, task = description.values_at(:entry, :task)
        pid = @spawner.spawn(description)
        started_at, started = stamp
        report(kind: :spawn, entry:, task:, pid:, at: started_at, changes: description[:changes])
        status = @spawner.wait(pid)
        finished_at, finished = stamp
        report(kind: :exit, entry:, task:, pid:, at: finished_at, status:, seconds: finished - started)
      end

      private

      # [wall-clock seconds since the epoch, monotonic seconds]
      def stamp = [@clock.clock_gettime(Process::CLOCK_REALTIME), @clock.clock_gettime(Process::CLOCK_MONOTONIC)]

      def report(**fields) = @reports.push(Ractor.make_shareable(fields))
    end
  end
end
