# frozen_string_literal: true

require "open3"

module Asgard
  # Questions about a pid that outlived the process that recorded it: is
  # it alive, what is it running, and is it still the process we started?
  # The watcher and background jobs both keep pids on disk across asgard
  # runs, and a pid left by a crash or a reboot can belong to an unrelated
  # process by the time it is read back. (Not Asgard::Process: that would
  # shadow ::Process inside the namespace.)
  module Pid
    # ps by absolute path: a scheduled or watched task's PATH may not
    # hold it.
    PS = %w[/bin/ps /usr/bin/ps].find { |path| File.executable?(path) } || "ps"

    # The system's ps cannot answer what these questions ask of it.
    class Unusable < Asgard::Error; end

    # One process of a group: its pid, when it started (to ps's one-second
    # resolution) and its command line.
    Member = Data.define(:pid, :started, :command)

    module_function

    # Whether a process exists; one we may not signal still exists.
    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # The ps argv for one pid's full command line. -ww: procps cuts the
    # line to the terminal width (COLUMNS) without it, and a job's script
    # path sits at the very end of a long one. macOS accepts it too.
    def ps_argv(pid) = [PS, "-ww", "-o", "command=", "-p", pid.to_s]

    # The command line of a live process as `ps` prints it, or nil when
    # there is no such process. ps is the one way that works unchanged
    # on macOS and Linux.
    def command_line(pid)
      out, status = Open3.capture2(*ps_argv(pid))
      status.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    # The command lines of every process in group +pgid+. ps by group id
    # is not portable, so this lists every process with its group and
    # keeps the matching ones (see group_commands).
    def group_command_lines(pgid)
      out, status = Open3.capture2(PS, "-ww", "-A", "-o", "pgid=,command=")
      status.success? ? group_commands(out, pgid) : []
    rescue SystemCallError
      []
    end

    # The commands in `ps -o pgid=,command=` output that belong to +pgid+.
    def group_commands(ps_output, pgid)
      ps_output.each_line.filter_map do |line|
        group, command = line.strip.split(/\s+/, 2)
        command.to_s if group.to_i == pgid
      end
    end

    # Every process in group +pgid+ as Members. Like group_command_lines,
    # but with each one's age, so a caller can tell a group that has kept
    # its members from a later group that reused the id.
    def group_processes(pgid, now: Time.now)
      out, status = Open3.capture2(PS, "-ww", "-A", "-o", "pid=,pgid=,etime=,command=")
      status.success? ? parse_group(out, pgid, now:) : []
    rescue SystemCallError
      []
    end

    # The Members of +pgid+ in `ps -o pid=,pgid=,etime=,command=` output.
    def parse_group(ps_output, pgid, now:)
      ps_output.each_line.filter_map do |line|
        pid, group, etime, command = line.strip.split(/\s+/, 4)
        Member.new(pid: pid.to_i, started: now - elapsed_seconds(etime), command: command.to_s) if group.to_i == pgid
      end
    end

    # Seconds in a ps etime, "[[dd-]hh:]mm:ss" (or bare seconds).
    def elapsed_seconds(etime)
      days, clock = etime.include?("-") ? etime.split("-", 2) : [0, etime]
      clock.split(":").map(&:to_i).reduce(0) { |total, part| (total * 60) + part } + (days.to_i * 86_400)
    end

    # Why +ps+ cannot answer for jobs, or nil when it can: it must accept
    # the flags command_line uses and name the current process. BusyBox
    # ps (Alpine) rejects -ww and -p; without this every job would look
    # gone and a second start would run a duplicate.
    def ps_problem(ps: PS)
      out, err, status = Open3.capture3(ps, "-ww", "-o", "pid=,command=", "-p", Process.pid.to_s)
      return err.lines.first.to_s.strip.then { it.empty? ? "exit status #{status.exitstatus}" : it } unless status.success?

      out.include?(Process.pid.to_s) ? nil : "it printed nothing for pid #{Process.pid}"
    rescue SystemCallError => e
      e.message
    end

    # Raises Unusable unless +ps+ works (see ps_problem); asks once per
    # process and ps.
    def require_ps!(ps: PS)
      @usable ||= {}
      problem = @usable.fetch(ps) { @usable[ps] = ps_problem(ps:) }
      return unless problem

      raise Unusable, "#{ps} cannot list processes: #{problem}. Background jobs need a ps that accepts " \
                      "-ww, -o and -p (procps on Linux, the system ps on macOS and BSD); on Alpine, `apk add procps`"
    end

    # Whether pid is alive and its command line carries every word. The
    # current process counts unless +self_ok+ is false: the watcher asks
    # about itself, but a job record naming our own pid is a reused pid.
    # An empty word matches nothing, since every command line holds "".
    # +command:+ supplies the command line in place of asking ps (tests,
    # or a caller that already has it).
    def matches?(pid, *words, command: nil, self_ok: true)
      return true if self_ok && pid == Process.pid

      command ||= command_line(pid)
      !command.nil? && words.all? { |word| !word.to_s.empty? && command.include?(word.to_s) }
    end
  end
end
