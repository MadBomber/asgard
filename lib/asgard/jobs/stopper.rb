# frozen_string_literal: true

module Asgard
  module Jobs
    # Ends one job: TERM to its process group, a poll every 0.2s for up to
    # the grace period, then KILL and a wait until the pid no longer
    # verifies. The signal sender, the liveness check and sleep are
    # injectable so the timing branches test without waiting.
    class Stopper
      POLL        = 0.2
      TIMEOUT     = 10
      WARN_AFTER  = 1.0

      # A negative pid addresses a group, and kill(2) gives -1 and 0 their
      # own meanings: every process the user owns, and the caller's own
      # group. A record that is corrupt or hand-written must never turn
      # into either, so only a real group id (above 1) is ever signalled.
      def self.signal_group(signal, pgid)
        unless pgid.is_a?(Integer) && pgid > 1
          raise ArgumentError,
                "refusing to signal process group #{pgid.inspect}: not a group id above 1"
        end

        Process.kill(signal, -pgid)
      rescue Errno::ESRCH
        nil
      end

      def initialize(timeout: TIMEOUT, poll: POLL, out: $stdout,
                     alive: State.method(:verified?), signal: Stopper.method(:signal_group), sleeper: Kernel.method(:sleep))
        @timeout = timeout
        @poll    = poll
        @out     = out
        @alive   = alive
        @signal  = signal
        @sleeper = sleeper
      end

      # :stopped when TERM ended the job within the grace period, :killed
      # when KILL had to, :not_running when there was nothing to stop.
      def stop(record)
        return :not_running unless @alive.call(record)

        @signal.call("TERM", record[:pgid])
        return :stopped if exited?(record)

        @signal.call("KILL", record[:pgid])
        exited?(record)
        :killed
      end

      # Stops and reports one job; the outcome as above.
      def stop_and_report(record)
        outcome = stop(record)
        @out.puts report_line(outcome, record)
        outcome
      end

      def report_line(outcome, record)
        name, pid = record.values_at(:name, :pid)
        case outcome
        when :stopped then "stopped #{name} (pid #{pid})"
        when :killed  then "killed #{name} (pid #{pid}) after #{@timeout}s"
        else               "#{name} is not running"
        end
      end

      private

      # True once the job is gone, false when the grace period ran out.
      # Says what it is waiting for once, when the wait reaches a second
      # (or its last poll, for a shorter grace period).
      def exited?(record)
        ticks = (@timeout / @poll).ceil
        warn_tick = [(WARN_AFTER / @poll).round, ticks].min - 1
        ticks.times do |tick|
          return true unless @alive.call(record)

          @sleeper.call(@poll)
          @out.puts "waiting for #{record[:name]} (pid #{record[:pid]})" if tick == warn_tick
        end
        !@alive.call(record)
      end
    end
  end
end
