# frozen_string_literal: true

require_relative "../schedule/declaration"

module Asgard
  module Watch
    # Builds the description of one task run: the argv, the complete
    # environment, and where it runs and logs. The dispatcher builds it in
    # the main Ractor, where ENV and the declarations live, and freezes it
    # with Ractor.make_shareable; the worker Ractor that spawns the task
    # sees nothing else, which is what keeps the daemon's own environment
    # out of the task. Everything here is pure.
    module Spawn
      # The only variables a task inherits from the daemon. Everything else
      # it sees comes from the declaration's env:, from .env and .envrc
      # loaded in the task's own process, or from the trigger itself.
      # GEM_*, RUBY* and BUNDLE(R)_* carry the Ruby setup the daemon itself
      # was started under (an rvm gemset, a vendored bundle, `bundle exec`),
      # without which the task's own asgard may not load.
      BASE_ENV_KEYS    = %w[PATH HOME USER LOGNAME SHELL LANG TMPDIR SSH_AUTH_SOCK GEM_HOME GEM_PATH RUBYOPT RUBYLIB].freeze
      BASE_ENV_PATTERN = /\A(?:LC_|BUNDLER?_)/

      # Bytes of change lists the environment carries; past this they go
      # to a file named in ASGARD_CHANGES_FILE. Argument and environment
      # space together is about 1 MB on macOS, and a branch switch under a
      # ** watch can change thousands of files.
      CHANGES_ENV_LIMIT = 128 * 1024

      # What every trigger of one daemon run shares: the real project root,
      # the log file tasks append to, the base environment captured at
      # start, the asgard executable, and direnv when it is on PATH.
      Context = Data.define(:root, :log, :base, :asgard, :direnv)

      module_function

      # The whitelisted variables of env (ENV by default).
      def base_env(env = ENV) = env.select { |key, _value| BASE_ENV_KEYS.include?(key) || key.match?(BASE_ENV_PATTERN) }

      # The task's full environment, lowest precedence first: the context's
      # base, the declaration's env:, the trigger variables.
      def environment(spec, changes, context, changes_file: nil)
        context.base.merge(spec[:env], { "ASGARD_WATCH" => spec[:name], "ASGARD_WATCH_ROOT" => context.root },
                           change_env(changes, changes_file))
      end

      # The trigger variables for +changes+, or only the name of +file+
      # when they would pass +limit+ bytes and there is a file to use.
      def change_env(changes, file, limit: CHANGES_ENV_LIMIT)
        vars = changes.to_env
        return vars if file.nil? || vars.sum { |key, value| key.bytesize + value.bytesize } <= limit

        { Changes::FILE_VARIABLE => file }
      end

      # The spill file for the +sequence+th trigger of +entry+, beside the log.
      def changes_file(context, entry, sequence) = File.join(File.dirname(context.log), "changes", "#{entry}-#{sequence}.json")

      # The task's argv: the context's asgard executable by absolute path, so
      # a trigger runs the very asgard that started the watcher whatever PATH
      # says, wrapped in direnv exec when available so .envrc loads in the
      # task's process.
      def argv(spec, context)
        direnv  = context.direnv
        wrapper = direnv ? [direnv, "exec", context.root] : []
        [*wrapper, context.asgard, spec[:task]]
      end

      # The asgard executable to run: the one running now when it is an
      # executable file named asgard (bin/asgard in a checkout, a gem
      # binstub when installed), else the first on path. A PATH scan could
      # find a different installed version than the one that started the
      # watcher.
      def executable(program = $PROGRAM_NAME, path = ENV.fetch("PATH", nil))
        running = File.expand_path(program)
        return running if File.basename(running) == "asgard" && File.file?(running) && File.executable?(running)

        Schedule.which("asgard", path)
      end

      # Everything a worker needs to run one trigger, deep-frozen and
      # Ractor-shareable: Strings, Arrays and Hashes only.
      # +changes_file+ is where the lists may spill; the description names
      # it as :changes_file only when they did.
      def description(spec, changes, context, changes_file: nil)
        env  = environment(spec, changes, context, changes_file:)
        desc = { entry: spec[:name], task: spec[:task], argv: argv(spec, context), env:,
                 root: context.root, log: context.log, changes: changes.to_h }
        desc[:changes_file] = changes_file if env.key?(Changes::FILE_VARIABLE)
        Ractor.make_shareable(desc)
      end
    end
  end
end
