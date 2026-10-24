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

    # The command line of a live process as `ps` prints it, or nil when
    # there is no such process. ps is the one way that works unchanged
    # on macOS and Linux.
    def command_line(pid)
      out, status = Open3.capture2(PS, "-o", "command=", "-p", pid.to_s)
      status.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    # Whether pid is alive and its command line carries every word. The
    # current process always counts. +command:+ supplies the command line
    # in place of asking ps (tests, or a caller that already has it).
    def matches?(pid, *words, command: nil)
      return true if pid == Process.pid

      command ||= command_line(pid)
      !command.nil? && words.all? { |word| command.include?(word.to_s) }
    end
  end
end
