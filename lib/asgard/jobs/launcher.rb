# frozen_string_literal: true

require "fileutils"
require "time"

module Asgard
  module Jobs
    # Starts a job: a new session with stdio detached, running the job's
    # shell under a POSIX /bin/sh trampoline that writes the exit status
    # to a file once nobody is left to wait on it. Everything but `launch`
    # is pure, and `launch` is three lines.
    module Launcher
      # The trampoline body. The trap is load-bearing: a group TERM reaches
      # this shell too, and an untrapped shell would die at once, before
      # the status is written. With a handler it finishes waiting for the
      # child, then runs on to the echo; the child still gets its own TERM
      # with the default disposition, since handled traps reset on exec.
      # Never `trap ''`: an ignored signal is inherited across exec. Two
      # commands, not one, so no shell execs the body away and vanishes.
      TRAMPOLINE = 'trap ":" TERM INT HUP; "$@"; echo $? > "$ASGARD_JOB_STATUS"'

      module_function

      # /bin/sh by absolute path: never bash and never a registry entry,
      # so the user's default_shell and the presence of bash do not
      # matter. The status path travels in the environment, so nothing
      # here is quoted.
      def argv(shell_argv) = ["/bin/sh", "-c", TRAMPOLINE, "asgard-job", *shell_argv]

      # The variables added to the task's environment. Python fully
      # buffers stdout when it is a file, so a print loop would show
      # nothing in the log until exit without PYTHONUNBUFFERED.
      def environment(name, status_path, env = ENV)
        added = { "ASGARD_JOB" => name.to_s, "ASGARD_JOB_STATUS" => status_path }
        added["PYTHONUNBUFFERED"] = "1" unless env.key?("PYTHONUNBUFFERED")
        added
      end

      # stdin from /dev/null, stdout and stderr appended to the log, so
      # the job never takes SIGTTIN or writes into a terminal that
      # happens to be attached.
      # close_others: a descriptor asgard inherited (a CI runner's, a
      # `3>file`) has no business staying open for the job's lifetime.
      def spawn_options(log_path) = { in: File::NULL, %i[out err] => [log_path, "a"], close_others: true }

      # Forks, starts a new session (pid = pgid = sid, no controlling
      # terminal) and execs; returns the child's pid, detached. The parent
      # waits on a pipe whose write end the child holds until exec closes
      # it (pipes are close-on-exec), so by the time the pid is recorded it
      # already leads its own group, and already runs the trampoline: a
      # `stop` issued at once signals the job, never the parent's group,
      # and a start issued at once sees the job's own command line.
      def launch(env, argv, options)
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          Process.setsid
          exec(env, *argv, **options)
        rescue SystemCallError => e
          # exit!, not raise: no at_exit handler of the parent may run here.
          $stderr.puts "asgard: could not start job: #{e.message}" # rubocop:disable Style/StderrPuts
          $stderr.flush # exit! skips Ruby's own flush
          exit!(127)
        end
        writer.close
        reader.read
        reader.close
        Process.detach(pid)
        pid
      end

      # Starts +run+ as the job +name+ owned by +task+, or returns the job
      # already running under that name. A missing shell exits 127 up
      # front, as foreground `sh` does; the trampoline would otherwise
      # hide it as a status nobody is watching for.
      def start(run, name:, task:, state:, silent: false, out: $stdout)
        state.with_lock(name) do
          existing = state.read_record(name)
          return already_running(existing, out:) if existing && state.verified?(existing)

          shell_missing!(run) unless Shell.resolve(run.shell[:path])
          job = spawn_job(run, name:, task:, state:)
          out.puts "started #{job.name} (pid #{job.pid}), log: #{job.log}" unless silent
          job
        end
      end

      def already_running(record, out:)
        out.puts "#{record[:name]} already running (pid #{record[:pid]}, started by #{record[:task]}), log: #{record[:log]}"
        Job.new(name: record[:name].to_sym, task: record[:task].to_sym, pid: record[:pid], log: record[:log])
      end

      def spawn_job(run, name:, task:, state:)
        state.prepare.remove(name)
        script = state.script_path(name, run.ext)
        log    = state.log_path(name)
        File.write(script, "#{run.script}\n")
        FileUtils.touch(log) # so `jobs log` and a reader never race the child's open
        pid = launch(environment(name, state.status_path(name)), argv(run.argv(script)), spawn_options(log))
        state.write_record(Jobs.record(name:, task:, pid:, pgid: pid, cwd: Dir.pwd, script:, log:,
                                       command: Jobs.summary(run.script), started: Time.now.iso8601(6)))
        Job.new(name: name.to_sym, task: task&.to_sym, pid:, log:)
      end

      # $stderr.puts, not warn: warn is silent under -W0 and this must show.
      def shell_missing!(run)
        $stderr.puts run.missing_message # rubocop:disable Style/StderrPuts
        exit 127
      end
    end
  end
end
