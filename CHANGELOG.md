# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`loki_up(name = ".loki")` Kernel method** — searches `Dir.pwd` and each ancestor directory for a file with the given name; returns the absolute path of the first match or `nil`. Available everywhere in Ruby (task bodies, `.loki` files, top-level code) as a `module_function` on `Kernel`.
- **`import(path)` Kernel method** — loads a `.loki` file (or a glob of `.loki` files) with `require`-like idempotency via `$LOADED_FEATURES`. Accepts a `String` or `Pathname`. Relative paths are resolved relative to the caller's file (like `require_relative`). Glob patterns (`*.loki`, `**/*.loki`) expand via `Dir.glob` and load all matches. Returns `true` if any file was newly loaded, `false` if all were already loaded or no glob matches were found. Raises `ArgumentError` if the path does not end with `.loki`.
- **`import_up(name = ".loki")` Kernel method** — combines `loki_up` and `import`. For exact names, finds the first ancestor directory containing that file and loads it. For glob names, finds the first ancestor directory containing any matching files and loads them all — stopping at that level rather than aggregating across multiple ancestors. Returns `false` if nothing is found.
- **`debug?` and `verbose?` Kernel module functions** — thin wrappers around `$DEBUG` and `$VERBOSE`, available everywhere in Ruby as `module_function` on `Kernel`. Set via `--debug` / `--verbose` CLI flags or directly via `$DEBUG` / `$VERBOSE`.
- **`env(name, default = nil)` Kernel method** — fetches a system environment variable by symbol or string name, upcasing the key automatically. `env(:port, "3000")` returns `"3000"` when `PORT` is unset; `env(:api_key)` raises `KeyError` when `API_KEY` is missing and no default is provided. Accepts both `env(:port)` and `env("PORT")` forms. Cleaner than `ENV['PORT']` in task bodies.
- **Verbose/debug feedback for `import` and `import_up`** — when `verbose?` is true, each file loaded is printed to stderr. When `debug?` is true, already-loaded files are also reported (with an "already loaded" suffix), and `import_up` reports when a file is not found.
- **RuboCop lint gate** — RuboCop is now a first-class quality gate alongside tests and Flog. Added `rubocop` to the Gemfile, a `.rubocop.yml` tuned for this codebase (Ruby 3.2 target, relaxed `Metrics` thresholds consistent with Flog as the primary complexity gate, `examples/` excluded), and `rake rubocop` / `rake rubocop_fix` tasks backed by a `tmp/rubocop_cache` directory for fast re-runs.
- **Expanded `rake quality` task** — `quality` now runs three independent gates (tests + coverage, RuboCop, Flog) and prints a formatted pass/fail summary table after all gates complete, so every failure is visible in a single run rather than stopping at the first.
- **`rake flog_check` task** — replaces the bare `flog lib/` call with a structured task that enforces per-method thresholds (warn ≥20, fail ≥50), lists warnings and failures in separate sections, and exits non-zero only when the failure threshold is breached.
- **Single-argument `desc` shorthand** — `desc` now accepts one string (the description) with the usage string omitted. The usage defaults to the method name, eliminating the redundant first argument for the common case:
  ```ruby
  desc "Run the test suite"   # usage defaults to "test"
  def test = sh "bundle exec rake test"
  ```
  The two-argument form (`desc "usage", "description"`) still works unchanged and is still required when the usage string differs from the method name (e.g. `desc "build NAME", "Build an artifact"`).

### Removed

- **`var` DSL method** — removed in favour of native Ruby class variables. Use `@@name ||= "value".freeze` in the class body. Class variables are visible in all task instance methods and in subcommand subclasses, making them the correct tool for shared configuration in a Thor-based task runner. Breaking change for projects using `var`.
- **`import` DSL method** — `import(mod)` was a one-line alias for Ruby's built-in `include`. Callers can use `include` directly.
- **`--auto-load` CLI flag** — sibling `*.loki` loading is now entirely user-controlled: place `import "*.loki"` (or any glob or explicit path) at the top of your `.loki` file to load additional task files. Breaking change for projects that relied on `--auto-load`.
- **`Asgard.load_loki(dir)`** — replaced by `import` with glob support. Callers can use `import(File.join(dir, "*.loki"))` directly.
- **`debug?` / `verbose?` private methods on `Tasks`** — removed as redundant. The identical `module_function` versions on `Kernel` are available everywhere, including inside task bodies.

### Refactored

- **`validate_deps!` decomposed into focused private helpers** — the method was performing four unrelated validations in one body (orphaned `depends_on` check, undefined dep name check, dep arity check, cycle detection). Each concern is now a dedicated `_`-prefixed private method (`_check_orphaned_deps!`, `_check_undefined_deps!`, `_check_dep_arities!`, `_build_and_sort_graph`). `validate_deps!` is now a sequencer of ~8 lines. Flog score dropped from 87.3 to 24.4.
- **`invoke_command` decomposed into focused private helpers** — the dispatch hook was handling deduplication gating, dependency graph resolution, parallel/sequential group execution, and completion signalling all in one 38-line method. Each concern is now extracted: `_acquire_run_token` (mutex check/wait/claim), `_run_deps_for` (graph build and group iteration), `_run_dep_group` (parallel thread fan-out vs inline), `_signal_done` (mutex mark-done and broadcast). `invoke_command` is now 10 lines. Flog score dropped from 109.8 to below the warning threshold.

### Fixed

- **Multiple parallel dep failures now all surfaced** — when two or more parallel deps raised, only the first exception was re-raised; the rest were silently discarded. All errors are now printed to stderr via `warn` before a general `Asgard::Error` is raised. When only one dep fails, its exception is re-raised directly as before.
- **Subcommand deps not validated at startup** — `run!` only called `Tasks.validate_deps!`, so circular dependencies and undefined dep names in subcommand groups were silently ignored. `run!` now snapshots `Asgard::Base.subclasses` before loading task files and validates every newly defined subclass alongside `Tasks`.
- **Parallel dep thread orphaned on exception** — when a parallel dep group contained one fast-failing task and one slow task, the join loop re-raised the first thread's exception and abandoned the remaining threads. The join loop now collects all thread exceptions before re-raising, ensuring every thread completes before execution exits the group.
- **Dep with required arguments gave a cryptic runtime error** — `depends_on :build` where `build(name)` has required parameters caused `Thor::InvocationError` at task invocation time with no indication of where the problem was. `validate_deps!` now checks arity via `instance_method.parameters` and raises `Asgard::Error` at startup with the task name and argument count.
- **Orphaned `depends_on` silently discarded** — a `depends_on` declaration at the end of a class body with no following `desc`/`def` left `@_pending_deps` non-empty but was ignored by `validate_deps!` due to an early `return if _deps.empty?` guard. `validate_deps!` now checks `@_pending_deps` before that guard and raises `Asgard::Error` naming the orphaned dependencies.
- **Single-arg `desc` options silently dropped** — when `desc "description", hide: true` was used, Ruby routed the options hash to the `description` positional parameter. The override now detects a `Hash` in the description position and treats it as options.
- **Single-arg `desc` stolen by `no_commands` blocks** — if a `no_commands` block appeared between a single-arg `desc` and its method, `method_added` consumed `@_pending_single_desc` for the interstitial helper and leaked a stale `@usage` onto the next real command. The fix: `@_pending_single_desc` is only consumed when `no_commands?` is false.
- **Parallel dep race condition** — when two parallel tasks shared a common dependency, the second thread could start before the shared dep finished. `_ran_tasks` (a single Set) has been replaced with `_running` / `_done` Sets and a per-task `ConditionVariable`. Threads that arrive at an already-running dep now wait for its completion.
- **`depends_on` silently dropped before `no_commands` blocks** — the `method_added` guard now checks `@usage` instead of the `no_commands?` counter, so `no_commands` helpers placed between `depends_on` and `def` no longer silently steal the dependency.
- **`shebang` ignored its `silent:` keyword argument** — the parameter was accepted but never referenced; the script body is now echoed to stdout unless `silent: true` is passed, matching the behavior of `sh`.

### Changed

- **`validate_deps!` detects undefined dependency names** — `depends_on :nonexistent` previously passed validation silently and produced no error at runtime. `validate_deps!` now raises `Asgard::Error` listing every dep name that does not correspond to a defined task.

## [0.2.0] - 2026-05-29

### Changed

- `*.loki` files are no longer auto-loaded by default. Pass `--auto-load` to `asgard` to load all `*.loki` files from the project root alphabetically before `.loki`. This is a breaking change for projects using the multi-file layout.
- Added `--auto-load` as a built-in CLI flag in `Tasks`, visible in `asgard help`

## [0.1.2] - 2026-05-29

### Added

- `--version` built-in CLI flag — prints `Asgard::VERSION` and exits; implemented as a `_`-prefixed method in `Tasks` per the gem-owned naming convention
- `--debug` and `--verbose` built-in `class_option` declarations on `Tasks` — set `$DEBUG`/`$VERBOSE` before any task runs via the `invoke_command` hook in `Asgard::Base`
- `debug?` and `verbose?` private predicate helpers on `Tasks` — thin wrappers around `$DEBUG` and `$VERBOSE` for use inside task bodies
- `_` prefix convention for gem-owned methods in `Tasks` — built-in methods use `_` prefix to distinguish them from user-defined tasks
- `run!` guards against direct invocation of `_`-prefixed commands with a clean error message and exit 1
- `examples/` directory with working `.loki` files:
  - `kitchen_sink.loki` — demonstrates the full Thor DSL (all option types, `long_desc`, `class_option`, `default_task`, `map`, `depends_on`, `var`, `no_commands`, `private`)
  - `server_subcommands.loki` — subcommand group for server management
  - `db_subcommands.loki` — subcommand group for database management with `depends_on` chaining
- README sections: Helper methods, Subcommands, Thor wrapper callout

### Fixed

- Replaced `warn`/`exit 1` with `abort` throughout `run!` — `Kernel#warn` is silenced when `$VERBOSE = nil`, which is the default in Ruby 4.0; `abort` writes to `$stderr` regardless

### Changed

- `--debug` and `--verbose` promoted from mapped tasks to `class_option` — they now work as modifiers alongside other commands (e.g. `asgard build --debug`) rather than as standalone commands
- Removed all references to `just` task runner and `recipe` terminology; Asgard uses "task" throughout
- `depends_on` parameter renamed from `*recipes` to `*tasks` for consistency

## [0.1.1] - 2026-05-28
### Added

- Parallel dependency execution — wrap deps in an array to run them concurrently:
  `depends_on [:build, :lint]` or `depends_on :setup, [:build, :lint], :deploy`
- `Asgard.run!(argv)` — single entry point encapsulating find, load, validate, and start
- `Asgard.load_loki(dir)` — auto-loads all `*.loki` files in a directory alphabetically
- `Tasks` class pre-defined by the gem (`class Tasks < Asgard::Base`) — task files reopen it without restating the superclass
- `lib/asgard/tasks.rb` — ships the pre-defined `Tasks` class

### Changed

- Replaced `SimpleFlow` dependency with `Dagwood` — purpose-built DAG library with no extra dependencies and no Ruby 4 compatibility issues
- `bin/asgard` simplified to two lines: `require "asgard"` + `Asgard.run!(ARGV)`
- Task file convention: `.loki` is the project root marker and entry point; `*.loki` files each reopen `class Tasks` and are auto-loaded before `.loki`
- `Asgard.find_task_files` renamed to `Asgard.find_task_file` (singular — only `.loki` is the entry point)
- `depends_on` now accepts mixed sequential/parallel stages; bare symbols run sequentially, arrays within the splat run in parallel
- `run!` handles its own errors — missing `.loki` and circular dependencies produce a clean one-line message and exit 1 rather than a backtrace
- Thread-safe dep deduplication via class-level `_ran_tasks` Set + Mutex replaces Thor's `@_invocations`
- Removed `import` macro — task files use Ruby class reopening instead of modules

### Removed

- `SimpleFlow` dependency (replaced by `Dagwood`)
- `logger` gem workaround (was only needed for SimpleFlow on Ruby 4)
- `*.loki` glob fallback in `find_task_file` — only `.loki` is the auto-discovered entry point

## [0.1.0] - 2026-05-28

### Added

- `Asgard::Base` — Thor subclass providing the task DSL
- `depends_on` — declare task dependencies; dependencies run at most once per invocation
- `var` — declare static or lazy-evaluated variables available to all tasks
- `import` — flat-merge a task module into the current class
- `dotenv` — load a `.env` file into the environment
- `sh` — run a shell command or multiline heredoc script; exits with the command's status on failure
- `shebang` — write a script body to a tempfile and execute it with a given interpreter (`:python3`, `:node`, `:ruby`, `:perl`, `:bash`, `:sh`, or any custom interpreter)
- `Asgard.find_task_files` — search current directory and ancestors for task files
- Task file resolution: `.loki` takes priority; falls back to all `*.loki` files sorted alphabetically
- `asgard` executable — finds task files, validates dependency graph, dispatches via Thor
- Circular dependency detection via `SimpleFlow::DependencyGraph` at startup
- 100% test coverage enforced via SimpleCov (95% minimum threshold)
- Quality task in `.loki` runs flog after tests

[Unreleased]: https://github.com/MadBomber/asgard/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/MadBomber/asgard/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/MadBomber/asgard/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/MadBomber/asgard/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/MadBomber/asgard/releases/tag/v0.1.0
