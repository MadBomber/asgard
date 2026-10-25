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

    # Whether pid is alive and its command line carries every word. The
    # current process counts unless +self_ok+ is false: the watcher asks
    # about itself, but a job record naming our own pid is a reused pid.
    # +command:+ supplies the command line in place of asking ps (tests,
    # or a caller that already has it).
    def matches?(pid, *words, command: nil, self_ok: true)
      return true if self_ok && pid == Process.pid

      command ||= command_line(pid)
      !command.nil? && words.all? { |word| command.include?(word.to_s) }
    end
  end
end
