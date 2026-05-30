# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Refactored

- **`validate_deps!` decomposed into focused private helpers** — the method was performing four unrelated validations in one body (orphaned `depends_on` check, undefined dep name check, dep arity check, cycle detection). Each concern is now a dedicated `_`-prefixed private method (`_check_orphaned_deps!`, `_check_undefined_deps!`, `_check_dep_arities!`, `_build_and_sort_graph`). `validate_deps!` is now a sequencer of ~8 lines. Flog score dropped from 87.3 to 24.4. The inline `rescue nil` on `instance_method` was also removed — by the time arity is checked, undefined deps have already been rejected, so the rescue was dead code.
- **`invoke_command` decomposed into focused private helpers** — the dispatch hook was handling deduplication gating, dependency graph resolution, parallel/sequential group execution, and completion signalling all in one 38-line method. Each concern is now extracted: `_acquire_run_token` (mutex check/wait/claim), `_run_deps_for` (graph build and group iteration), `_run_dep_group` (parallel thread fan-out vs inline), `_signal_done` (mutex mark-done and broadcast). `invoke_command` is now 10 lines. Flog score dropped from 109.8 to below the warning threshold. The `rubocop:disable` comments on the method are removed.

### Added

- **RuboCop lint gate** — RuboCop is now a first-class quality gate alongside tests and Flog. Added `rubocop` to the Gemfile, a `.rubocop.yml` tuned for this codebase (Ruby 3.2 target, relaxed `Metrics` thresholds consistent with Flog as the primary complexity gate, `examples/` excluded), and `rake rubocop` / `rake rubocop_fix` tasks backed by a `tmp/rubocop_cache` directory for fast re-runs.
- **Expanded `rake quality` task** — `quality` now runs three independent gates (tests + coverage, RuboCop, Flog) and prints a formatted pass/fail summary table after all gates complete, so every failure is visible in a single run rather than stopping at the first.
- **`rake flog_check` task** — replaces the bare `flog lib/` call with a structured task that enforces per-method thresholds (warn ≥20, fail ≥50), lists warnings and failures in separate sections, and exits non-zero only when the failure threshold is breached. Current known failures (`invoke_command` at 109.8, `validate_deps!` at 87.3) are tracked here and suppressed in RuboCop via scoped `disable/enable` comments.

- **Single-argument `desc` shorthand** — `desc` now accepts one string (the description) with the usage string omitted. The usage defaults to the method name, eliminating the redundant first argument for the common case:
  ```ruby
  desc "Run the test suite"   # usage defaults to "test"
  def test = sh "bundle exec rake test"
  ```
  The two-argument form (`desc "usage", "description"`) still works unchanged and is still required when the usage string differs from the method name (e.g. `desc "build NAME", "Build an artifact"`).

### Fixed (round 2)

- **Subcommand deps not validated at startup** — `run!` only called `Tasks.validate_deps!`, so circular dependencies and undefined dep names in subcommand groups (classes that inherit from `Asgard::Base` or `Tasks`) were silently ignored. `run!` now snapshots `Asgard::Base.subclasses` before loading task files and validates every newly defined subclass alongside `Tasks`.
- **Parallel dep thread orphaned on exception** — when a parallel dep group contained one fast-failing task and one slow task, `threads.each(&:join)` re-raised the first thread's exception and abandoned the remaining threads. The slow thread continued running unsupervised after the caller saw the exception. The join loop now collects all thread exceptions before re-raising the first, ensuring every thread completes before execution exits the group.
- **Dep with required arguments gave a cryptic runtime error** — `depends_on :build` where `build(name)` has required parameters caused `Thor::InvocationError` at task invocation time with no indication of where the problem was. `validate_deps!` now checks the arity of every dep task via `instance_method.parameters` and raises `Asgard::Error` at startup with the task name and required argument count.
- **Orphaned `depends_on` silently discarded** — a `depends_on` declaration at the end of a class body (or `.loki` file) with no following `desc`/`def` left `@_pending_deps` non-empty but was ignored by `validate_deps!` due to an early `return if _deps.empty?` guard. `validate_deps!` now checks `@_pending_deps` before that guard and raises `Asgard::Error` naming the orphaned dependencies.
- **Single-arg `desc` options silently dropped** — when `desc "description", hide: true` was used, Ruby routed the options hash to the `description` positional parameter rather than `options`. The override now detects a `Hash` in the description position and treats it as options, and caches options alongside the pending description so they are forwarded when `method_added` resolves the usage string.
- **Single-arg `desc` stolen by `var` and `no_commands` blocks** — if a `var` declaration or `no_commands` block appeared between a single-arg `desc` and its method, `method_added` consumed `@_pending_single_desc` for the interstitial helper method and set the wrong `@usage` value. Because Thor's `method_added` returns early for `no_commands?` without clearing `@usage`, that stale value then leaked onto the next real command. The fix mirrors two-arg `desc` behavior: `@_pending_single_desc` is only consumed when `no_commands?` is false.

### Fixed

- **Parallel dep race condition** — when two parallel tasks shared a common dependency, the second thread could start before the shared dep finished executing. `_ran_tasks` (a single Set) has been replaced with `_running` / `_done` Sets and a per-task `ConditionVariable`. Threads that arrive at an already-running dep now wait for its completion rather than skipping it; the `ensure` block broadcasts completion whether the task succeeds or raises.
- **`depends_on` silently dropped before `var` or `no_commands`** — Thor uses an integer counter for `@no_commands` that resets to `0` (truthy in Ruby) after any `no_commands` block. The `method_added` guard now checks `@usage` instead: pending deps are only consumed when a command-defining method is added (one preceded by `desc`), so `var` declarations and `no_commands` helpers placed between `depends_on` and `def` no longer silently steal the dependency.
- **`shebang` ignored its `silent:` keyword argument** — the parameter was accepted but never referenced; the script body is now echoed to stdout unless `silent: true` is passed, matching the behavior of `sh`.
- **`var` lambdas re-evaluated on every access** — the accessor method now caches its result in a per-instance variable on first call. Lambdas used for computed values (e.g. `` -> { `git describe --tags`.strip } ``) now run exactly once per instance.

### Changed

- **`validate_deps!` detects undefined dependency names** — `depends_on :nonexistent` previously passed validation silently and produced no error at runtime. `validate_deps!` now raises `Asgard::Error` listing every dep name that does not correspond to a defined task. `run!` catches this alongside `CircularDependencyError` and exits with a clean message.

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
