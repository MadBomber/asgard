# frozen_string_literal: true

module Asgard
  module Jobs
    # Ends one job: TERM to its process group, a poll every 0.2s for up to
    # the grace period, then KILL and a wait until the group holds none of
    # the job's processes. The signal sender, the liveness check and
    # sleep are injectable so the timing branches test without waiting.
    class Stopper
      POLL        = 0.2
      TIMEOUT     = 10
      WARN_AFTER  = 1.0
      RESEND_EVERY = 1.0

      # A negative pid addresses a group, and kill(2) gives -1 and 0 their
      # own meanings: every process the user owns, and the caller's own
      # group. A record that is corrupt or hand-written must never turn
      # into either, so only a real group id (above 1) is ever signalled.
      #
      # A valid id is still refused (false) when it is our own group, or
      # when no process leads it any more: a job's pgid is its trampoline's
      # pid, so a group whose leader is gone or moved is not the job. So is
      # a group we may not signal (EPERM): its id now belongs to another
      # user's processes. +kill+ is Process.kill, injectable for tests.
      def self.signal_group(signal, pgid, own_pgrp: Process.getpgrp, pgid_of: Process.method(:getpgid),
                            kill: Process.method(:kill))
        unless pgid.is_a?(Integer) && pgid > 1
          raise ArgumentError,
                "refusing to signal process group #{pgid.inspect}: not a group id above 1"
        end
        return false unless led_or_orphaned?(pgid, own_pgrp:, pgid_of:, kill:)

        kill.call(signal, -pgid)
      rescue Errno::ESRCH
        nil
      rescue Errno::EPERM
        false
      end

      # A group may be signalled when its leader (the trampoline) still
      # leads it, or when the leader is gone but members remain: then the
      # id cannot have been reused. Never our own group, and never one we
      # may not signal (EPERM). ESRCH from the group check means nobody is
      # left: nil from signal_group.
      def self.led_or_orphaned?(pgid, own_pgrp:, pgid_of:, kill: Process.method(:kill))
        return false if pgid == own_pgrp

        leader_group = begin
          pgid_of.call(pgid)
        rescue Errno::ESRCH
          kill.call(0, -pgid) # members without their leader, or ESRCH
          pgid
        end
        safe_group?(pgid, pid: pgid, own_pgrp:, pgid_of: ->(_) { leader_group })
      rescue Errno::EPERM
        false
      end

      # Whether +pgid+ may be signalled as the group +pid+ leads: a group id
      # above 1, not our own, and still the group +pid+ belongs to.
      def self.safe_group?(pgid, pid:, own_pgrp:, pgid_of:)
        return false unless pgid.is_a?(Integer) && pgid > 1 && pgid != own_pgrp

        pgid_of.call(pid) == pgid
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      # +alive+ is State.active?: a job whose script exited still counts
      # while processes it left run in its group, and ps has confirmed
      # they are there before any signal goes out.
      def initialize(timeout: TIMEOUT, poll: POLL, out: $stdout,
                     alive: State.method(:active?), signal: Stopper.method(:signal_group), sleeper: Kernel.method(:sleep))
        @timeout = timeout
        @poll    = poll
        @out     = out
        @alive   = alive
        @signal  = signal
        @sleeper = sleeper
      end

      # :stopped when TERM ended the job within the grace period, :killed
      # when KILL had to, :not_running when there was nothing to stop. A
      # KILL takes the trampoline too, so the 137 is recorded here (a
      # record that is not a job's, as the timing tests use, writes none).
      def stop(record)
        return :not_running unless @alive.call(record)

        @signal.call("TERM", record[:pgid])
        return :stopped if exited?(record, resend: "TERM")

        @signal.call("KILL", record[:pgid])
        State.record_kill(record) if exited?(record)
        :killed
      end

      # Whether poll number +tick+ (from 0) re-sends TERM: once every
      # RESEND_EVERY seconds. A TERM that reached the trampoline's child
      # between its fork and its exec met the inherited trap and was lost;
      # by the next one the child runs the job with the default handler.
      def self.resend_tick?(tick, poll:)
        every = (RESEND_EVERY / poll).round
        tick.positive? && (tick % every).zero?
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
      def exited?(record, resend: nil)
        ticks = (@timeout / @poll).ceil
        warn_tick = [(WARN_AFTER / @poll).round, ticks].min - 1
        ticks.times do |tick|
          return true unless @alive.call(record)

          @signal.call(resend, record[:pgid]) if resend && Stopper.resend_tick?(tick, poll: @poll)
          @sleeper.call(@poll)
          @out.puts "waiting for #{record[:name]} (pid #{record[:pid]})" if tick == warn_tick
        end
        !@alive.call(record)
      end
    end
  end
end
