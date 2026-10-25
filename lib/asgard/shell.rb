# frozen_string_literal: true

require "English"
require "pathname"
require "shellwords"
require "tempfile"
require_relative "schedule/declaration"

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
      "bash" => ".sh", "sh" => ".sh", "zsh" => ".sh", "fish" => ".fish", "csh" => ".csh", "tcsh" => ".csh",
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

      # Build a normalized entry. A String +path+ is split with Shellwords:
      # the first word is the executable, the rest are arguments and come
      # before +args+, which may be a String (also Shellwords-split) or an
      # Array. A Pathname +path+ is the executable as is, spaces and all.
      # +ext+ is derived from the executable's basename when omitted.
      def entry(path, args: nil, ext: nil)
        words = path_words(path)
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

      # The executable and any leading arguments a path gives: a Pathname
      # names one file and is never split; anything else is a String with
      # shell quoting.
      def path_words(path)
        return path.to_s.empty? ? [] : [path.to_s] if path.is_a?(Pathname)

        Shellwords.split(path.to_s)
      end

      # The name a bare path registers under: the executable's basename.
      # "/usr/local/bin/bash -c -w" is :bash, "uv run --script" is :uv.
      def name_for(entry) = File.basename(entry[:path]).to_sym

      # The file an entry's executable names, or nil: a path with a
      # directory part must be an executable file as given (no ~ or PATH
      # expansion, since none happens when it runs); a bare name must be
      # found on +env_path+.
      def resolve(executable, env_path = ENV.fetch("PATH", nil))
        return Schedule.which(executable, env_path) unless executable.include?(File::SEPARATOR)

        executable if File.file?(executable) && File.executable?(executable)
      end

      # +entry+ when its executable resolves; ArgumentError naming the
      # shell otherwise, so a .loki fails as it loads rather than with an
      # exit 127 the first time a task runs.
      def validate!(name, entry, env_path = ENV.fetch("PATH", nil))
        return entry if resolve(entry[:path], env_path)

        problem = entry[:path].include?(File::SEPARATOR) ? "is not an executable file" : "is not an executable on PATH"
        raise ArgumentError, "shell #{name.inspect}: #{entry[:path]} #{problem}"
      end

      # The entry for +name+, or a bare fallback that runs +name+ itself as
      # found on PATH.
      def shell_for(name)
        shells.fetch(name.to_sym) { { path: name.to_s, args: [].freeze, ext: DEFAULT_EXTENSIONS.fetch(name.to_s, ".tmp") }.freeze }
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

      # `default_shell :zsh` selects the shell `sh` runs, leaving the
      # registry alone; with no argument it returns the current name. Any
      # other form registers first, through `shell`, then selects:
      #
      #   default_shell "/usr/local/bin/bash -c -w"           # :bash
      #   default_shell :strict, "bash", args: "-eu -o pipefail"
      #   default_shell :zsh, args: "-f"                      # path is the name
      def default_shell(name_or_path = nil, path = nil, args: nil, ext: nil)
        return Shell.default_shell unless name_or_path

        selecting = name_or_path.is_a?(Symbol) && !(path || args || ext)
        Shell.default_shell(selecting ? selectable!(name_or_path) : shell(name_or_path, path, args:, ext:))
      end

      # Register a shell and return its name. With a Symbol first:
      #
      #   shell :strict, "bash -eu -o pipefail"
      #   shell :uv, "uv run --script", ext: ".py"
      #   shell :fish                          # fish from PATH, defaults
      #
      # With a bare path (String or Pathname) the name is the executable's
      # basename, and any options in the string are parsed into args:
      #
      #   shell "/usr/local/bin/bash -c -w"    # :bash, args ["-c", "-w"]
      #
      # The executable must exist: an executable file at that path, or a
      # bare name found on PATH. Otherwise ArgumentError, as the .loki loads.
      def shell(name_or_path, path = nil, args: nil, ext: nil)
        name, path = split_shell_args(name_or_path, path)
        entry      = Shell.entry(path, args:, ext:)
        name     ||= Shell.name_for(entry)
        Shell.shells[name] = Shell.validate!(name, entry)
        name
      end

      private

      # +name+ when it is registered or runs as itself from PATH; otherwise
      # ArgumentError as the .loki loads, as `shell` does for a bad path.
      def selectable!(name)
        return name if Shell.shells.key?(name)

        Shell.validate!(name, Shell.shell_for(name))
        name
      end

      # The [name, path] of a `shell` call: a Symbol first is the name, and
      # its path defaults to the name itself; a String or Pathname first is
      # the path, and the name comes from the entry.
      def split_shell_args(name_or_path, path)
        return [nil, name_or_path] unless name_or_path.is_a?(Symbol)

        [name_or_path, path || name_or_path.to_s]
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
    #
    # background: true starts the script as a job named after the calling
    # task (`doc_server-1`); a Symbol or String names the job itself. The
    # call returns a Jobs::Job at once and the job outlives asgard; see
    # `asgard jobs`.
    def shebang(name_or_script, script = nil, silent: false, background: nil)
      name, script = script ? [name_or_script, script] : [Shell.default_shell, name_or_script]
      run = Run.new(name:, shell: Shell.shell_for(name), script: script.strip)
      job = background_job_name(background)
      $stdout.puts run.script unless silent
      job ? start_job(run, job, silent:) : run_script(run)
    end

    private

    # The job name a background: value asks for; only `true` consumes a
    # sequence number, and only inside a task body.
    def background_job_name(background)
      return nil unless background

      task     = current_task
      sequence = next_job_sequence if background == true && task
      Jobs.job_name(background, task:, sequence:)
    end

    def start_job(run, name, silent:)
      root  = Asgard.project_root
      state = Jobs::State.new(project: Schedule.project_slug(root), root:)
      Jobs::Launcher.start(run, name:, task: current_task, state:, silent:)
    end

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
