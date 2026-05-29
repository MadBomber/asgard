# frozen_string_literal: true

require "tempfile"

module Asgard
  module Shell
    # Run a shell script. Multiline strings are passed to bash -c; single-line
    # strings are passed to system directly. Exits with the command's status
    # code on failure.
    def sh(script, silent: false)
      script = script.strip
      $stdout.puts script unless silent

      success = if script.include?("\n")
        system("bash", "-c", script)
      else
        system(script)
      end

      exit($?.exitstatus) unless success
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
        exit($?.exitstatus) unless $?.success?
      end
    end
  end
end
