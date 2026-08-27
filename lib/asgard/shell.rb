# frozen_string_literal: true

require 'English'
require "tempfile"

module Asgard
  module Shell
    # Run a shell script. Multiline strings are passed to bash -c; single-line
    # strings are passed to system directly. Exits with the command's status
    # code on failure.
    #
    # Pass exec: true to replace the current process instead of forking —
    # useful for a task's final, long-running command (e.g. a dev server)
    # so the asgard/ruby process doesn't sit resident in memory alongside it.
    def sh(script, silent: false, exec: false)
      script = script.strip
      $stdout.puts script unless silent
      argv = shell_argv(script)

      if exec
        $stdout.flush
        Kernel.exec(*argv)
      else
        exit($CHILD_STATUS.exitstatus) unless system(*argv)
      end
    end

    # Write +script+ to a tempfile and execute it with +interpreter+.
    # Useful for embedding Python, Node, Ruby, or any shebang-style body.
    def shebang(interpreter, script, silent: false)
      extensions = {
        python3: ".py", python: ".py",
        node:    ".js",
        ruby:    ".rb",
        perl:    ".pl",
        bash:    ".sh", sh: ".sh"
      }
      ext = extensions.fetch(interpreter.to_sym, ".tmp")

      $stdout.puts script unless silent

      Tempfile.create(["asgard_", ext]) do |f|
        f.write(script)
        f.flush
        system(interpreter.to_s, f.path)
        exit($CHILD_STATUS.exitstatus) unless $CHILD_STATUS.success?
      end
    end

    private

    # The argv passed to system/exec for +script+: multi-line scripts run
    # through `bash -c` so assignments carry across lines; single-line
    # scripts run directly.
    def shell_argv(script)
      script.include?("\n") ? ["bash", "-c", script] : [script]
    end
  end
end
