# frozen_string_literal: true

require "English"
require "shellwords"
require "tempfile"

module Asgard
  # `shebang` is the one way a task runs something that isn't Ruby. The script
  # is written to a tempfile and the file is handed to an interpreter from the
  # `shells` registry, so one line and fifty lines take the same path:
  #
  #   shebang :bash,    "rake build"
  #   shebang :python3, <<~PY
  #     print("hi")
  #   PY
  #
  # The name may be left out, and `sh script` is the same call: both run the
  # `default_shell`, which starts as :bash. The registry maps a name to the
  # executable, the arguments placed before the script, and the tempfile
  # extension:
  #
  #   Tasks.shells[:bash]  # => { path: "bash", args: [], ext: ".sh" }
  #
  # `shell` at class level adds or replaces an entry. A name that isn't
  # registered runs as itself, found on PATH, with a `.tmp` extension.
  module Shell
    # The extension a declaration gets when `ext:` is omitted, keyed by the
    # basename of its executable. Node needs `.js` to load ES modules.
    DEFAULT_EXTENSIONS = {
      "bash" => ".sh", "sh" => ".sh", "zsh" => ".sh", "fish" => ".fish",
      "python3" => ".py", "python" => ".py",
      "node" => ".js", "ruby" => ".rb", "perl" => ".pl"
    }.freeze

    SEEDED_SHELLS = %w[bash sh python3 python node ruby perl].freeze

    class << self
      # The registry: name => { path:, args:, ext: }. One table for every
      # Tasks subclass, seeded with the interpreters above.
      def shells
        @shells ||= SEEDED_SHELLS.to_h { |name| [name.to_sym, entry(name)] }
      end

      # The shell `sh` and a nameless `shebang` run; :bash until a .loki says
      # otherwise.
      def default_shell(name = nil)
        @default_shell = name.to_sym if name
        @default_shell ||= :bash
      end

      # Restore the seeded registry and default (tests).
      def reset_shells!
        @shells        = nil
        @default_shell = nil
      end

      # Build a normalized entry. +path+ is split with Shellwords: the first
      # word is the executable, the rest are arguments and come before +args+,
      # which may be a String (also Shellwords-split) or an Array. +ext+ is
      # derived from the executable's basename when omitted.
      def entry(path, args: nil, ext: nil)
        words = Shellwords.split(path.to_s)
        raise ArgumentError, "shell path is empty" if words.empty?

        executable = words.shift
        {
          path: executable,
          args: (words + split_args(args)).freeze,
          ext:  ext || DEFAULT_EXTENSIONS.fetch(File.basename(executable), ".tmp")
        }.freeze
      end

      def split_args(args)
        case args
        when nil    then []
        when String then Shellwords.split(args)
        else             Array(args).map(&:to_s)
        end
      end

      # The entry for +name+, or a bare fallback that runs +name+ itself as
      # found on PATH.
      def shell_for(name)
        shells.fetch(name.to_sym) { { path: name.to_s, args: [].freeze, ext: ".tmp" }.freeze }
      end

      # The argv that runs +file+ with +shell+.
      def argv(shell, file)
        [shell[:path], *shell[:args], file]
      end

      # A process's exit code as a shell reports it: its status, or 128
      # plus the signal number when a signal ended it.
      def exit_code(status) = status.exitstatus || (128 + status.termsig)
    end

    module ClassMethods
      def shells = Shell.shells

      # `default_shell :zsh` sets the shell `sh` runs; with no argument,
      # returns it.
      def default_shell(name = nil) = Shell.default_shell(name)

      # Register +name+: `shell :strict, "bash -eu -o pipefail"`,
      # `shell :uv, "uv run --script", ext: ".py"`.
      def shell(name, path, args: nil, ext: nil)
        Shell.shells[name.to_sym] = Shell.entry(path, args:, ext:)
      end
    end

    def self.included(base) = base.extend(ClassMethods)

    # One shebang call: the shell name the task gave, its registry entry and
    # the stripped script.
    Run = Data.define(:name, :shell, :script) do
      def ext = shell[:ext]
      def argv(file) = Shell.argv(shell, file)
      def missing_message = "asgard: shell #{name.inspect} not found: #{argv('...').shelljoin}"
    end

    # Run +script+ with the default shell. Exits with the command's status on
    # failure.
    def sh(script, **) = shebang(script, **)

    # Write +script+ to a tempfile and run it with the shell registered as
    # +name+, or with the default shell when only the script is given.
    # Returns true; exits with the command's status code on failure.
    def shebang(name_or_script, script = nil, silent: false)
      name, script = script ? [name_or_script, script] : [Shell.default_shell, name_or_script]
      run = Run.new(name:, shell: Shell.shell_for(name), script: script.strip)
      $stdout.puts run.script unless silent
      run_script(run)
    end

    private

    def run_script(run)
      Tempfile.create(["asgard_", run.ext]) do |f|
        f.write(run.script)
        f.flush
        success = system(*run.argv(f.path))
        shell_missing!(run) if success.nil?
        exit(Shell.exit_code($CHILD_STATUS)) unless success
        true
      end
    end

    # $stderr.puts, not warn: warn is silent under -W0 and this must show.
    def shell_missing!(run)
      $stderr.puts run.missing_message # rubocop:disable Style/StderrPuts
      exit 127
    end
  end
end
