# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.3] - 2026-08-27

### Added

- **`helper(name, &block)` DSL method on `Asgard::Base`** — defines a method available in both class context (e.g. inside `header` or `footer`) and as a private instance method inside task bodies, with a single declaration. Eliminates the manual `def self.name` + `no_commands { private def name = self.class.name }` boilerplate. Supports positional arguments, keyword arguments, default values, and block arguments.
  ```ruby
  class Tasks
    @@project ||= "myapp".freeze

    helper(:version) {
      File.read("lib/myapp/version.rb").match(/VERSION\s*=\s*"([^"]+)"/)[1].freeze
    }

    header "#{@@project} v#{version}"   # class context

    desc "Show the current version"
    def show_version = puts version     # instance context
  end
  ```

- **`header(text)` and `footer(text)` DSL methods on `Asgard::Base`** — attach static text to the general help output. `header` lines are printed above the commands list; `footer` lines are printed below the options block. Multiple calls accumulate: each `header` call appends a line, each `footer` call prepends a line, so content from later-loaded files naturally wraps around content from earlier files. Neither appears when `asgard help <command>` is called for per-command detail.
  ```ruby
  class Tasks
    header "my-project — build & release tasks"
    footer "See https://example.com/docs for details"
  end
  ```
- **`no_negate(*names)` DSL method on `Asgard::Base`** — suppresses the `[--no-name]` and `[--skip-name]` negation variants from help output for boolean class options where negation is meaningless. Call it after the `class_option` declaration:
  ```ruby
  class_option :version, type: :boolean, default: false, desc: "Show version and exit"
  no_negate :version
  ```

### Changed

- **`--version` reimplemented as a `class_option`** — the flag now appears in the "Options" section of `asgard help` alongside `--debug` and `--verbose`, rather than as a listed command. The `_version` method and its `map "--version" => :_version` registration have been removed. The actual early-exit behaviour still lives in `Asgard.run!` (before the `.loki` file is required), so `--version` works even when no `.loki` file exists. `no_negate :version` suppresses the spurious `[--no-version]` / `[--skip-version]` variants.
- **`loki_up` returns `Pathname` instead of `String`** — the return value is now a `Pathname` instance (or `nil` when not found). `Pathname` is accepted everywhere `loki_up`'s result is used: `import`, `dotenv`, `load`, and standard Ruby file methods all accept `Pathname` via `to_path` / `to_s`. Code that passes the result directly to those methods is unaffected; code that performs string operations on the path should call `.to_s` first.

### Fixed

- **Help output showed `tasks` prefix before every command** — `asgard help` displayed `asgard tasks build` instead of `asgard build`. The cause was a keyword-vs-positional mismatch in the `Asgard::Base#help` override: declaring `subcommand: false` as a keyword argument caused Ruby's `super` to forward it as the hash `{subcommand: false}`. Thor's `banner` method received this hash as the positional `subcommand` argument, treated it as truthy, and prepended the class namespace (`tasks`) to every command name. Fixed by changing the override signature to match Thor's positional signature: `def help(command = nil, subcommand = false)`.

### Added (continued)

- **`loki_up(name = ".loki")` Kernel method** — searches `Dir.pwd` and each ancestor directory for a file with the given name; returns the absolute path of the first match or `nil`. Available everywhere in Ruby (task bodies, `.loki` files, top-level code) as a `module_function` on `Kernel`.
- **`import(path)` Kernel method** — loads a `.loki` file (or a glob of `.loki` files) with `require`-like idempotency via `$LOADED_FEATURES`. Accepts a `String` or `Pathname`. Relative paths are resolved relative to the caller's file (like `require_relative`). Glob patterns (`*.loki`, `**/*.loki`) expand via `Dir.glob` and load all matches. Returns `true` if any file was newly loaded, `false` if all were already loaded or no glob matches were found. Raises `ArgumentError` if the path does not end with `.loki`.
- **`import_up(name = ".loki")` Kernel method** — combines `loki_up` and `import`. For exact names, finds the first ancestor directory containing that file and loads it. For glob names, finds the first ancestor directory containing any matching files and loads them all — stopping at that level rather than aggregating across multiple ancestors. Returns `false` if nothing is found.
- **`debug?` and `verbose?` Kernel module functions** — thin wrappers around `$DEBUG` and `$VERBOSE`, available everywhere in Ruby as `module_function` on `Kernel`. Set via `--debug` / `--verbose` CLI flags or directly via `$DEBUG` / `$VERBOSE`.
- **`env(name, default = nil)` Kernel method** — fetches a system environment variable by symbol or string name, upcasing the key automatically. `env(:port, "3000")` returns `"3000"` when `PORT` is unset; `env(:api_key)` raises `KeyError` when `API_KEY` is missing and no default is provided. Accepts both `env(:port)` and `env("PORT")` forms. Cleaner than `ENV['PORT']` in task bodies.
- **Verbose/debug feedback for `import` and `import_up`** — when `verbose?` is true, each file loaded is printed to stderr. When `debug?` is true, already-loaded files are also reported (with an "already loaded" suffix), and `import_up` reports when a file is not found.
- **RuboCop lint gate** — RuboCop is now a first-class quality gate alongside tests and Flog. Added `rubocop` to the Gemfile, a `.rubocop.yml` tuned for this codebase (Ruby 3.2 target, relaxed `Metrics` thresholds consistent with Flog as the primary complexity gate, `examples/` excluded), and `rake rubocop` / `rake rubocop_fix` tasks backed by a `tmp/rubocop_cache` directory for fast re-runs.
- **Expanded `rake quality` task** — `quality` now runs three independent gates (tests + coverage, RuboCop, Flog) in parallel using `depends_on [:test, :rubocop, :flog_check]`. Each gate captures its pass/fail result in an instance variable; output is suppressed on pass and filtered to failures only on fail, preventing interleaved output from concurrent subprocesses. A formatted pass/fail summary table is printed after all gates complete, so every failure is visible in a single run.
- **`rake flog_check` task** — replaces the bare `flog lib/` call with a structured task that enforces per-method thresholds (warn ≥20, fail ≥50), lists warnings and failures in separate sections, and exits non-zero only when the failure threshold is breached.
- **Single-argument `desc` shorthand** — `desc` now accepts one string (the description) with the usage string omitted. The usage defaults to the method name, eliminating the redundant first argument for the common case:
  ```ruby
  desc "Run the test suite"   # usage defaults to "test"
  def test = sh "bundle exec rake test"
  ```
  The two-argument form (`desc "usage", "description"`) still works unchanged and is still required when the usage string differs from the method name (e.g. `desc "build NAME", "Build an artifact"`).
- **`default_task` override warning** — `Asgard::Base` now overrides Thor's `default_task` to warn to stderr when a second call would silently replace the first. The warning includes the task name, file, and line number for both the original declaration and the override, making accidental cross-file clobbering visible immediately.
- **`examples/env_usage.loki` and `examples/.env`** — demonstrate the `env()` Kernel helper, including the default-fallback form (`env(:log_level, "info")`) for variables absent from the environment. Uses `loki_up(".env")` so `dotenv` locates the `.env` file correctly regardless of which directory `asgard` is invoked from.
- **`examples/subdir/`** — three-file demo showing `import` and `import_up` across directory boundaries: `subdir/.loki` imports `import_up_demo.loki` by name; `import_up_demo.loki` calls `import_up "env_usage.loki"` to locate and load a file from an ancestor directory without a hardcoded path.
- **`status` task in `kitchen_sink.loki`** — demonstrates `debug?` and `verbose?` predicates with conditional output; shows `--debug` printing `$DEBUG`, `$VERBOSE`, and the full options hash.
- **Computed value methods in `kitchen_sink.loki`** — three private methods (`version`, `sha`, `branch`) demonstrating the idiomatic Ruby replacement for the removed `var` DSL, including memoization via `@ivar ||=`.

### Removed

- **`var` DSL method** — removed in favour of native Ruby class variables. Use `@@name ||= "value".freeze` in the class body. Class variables are visible in all task instance methods and in subcommand subclasses, making them the correct tool for shared configuration in a Thor-based task runner. Breaking change for projects using `var`.
- **`import` DSL method** — `import(mod)` was a one-line alias for Ruby's built-in `include`. Callers can use `include` directly.
- **`--auto-load` CLI flag** — sibling `*.loki` loading is now entirely user-controlled: place `import "*.loki"` (or any glob or explicit path) at the top of your `.loki` file to load additional task files. Breaking change for projects that relied on `--auto-load`.
- **`Asgard.load_loki(dir)`** — replaced by `import` with glob support. Callers can use `import(File.join(dir, "*.loki"))` directly.
- **`debug?` / `verbose?` private methods on `Tasks`** — removed as redundant. The identical `module_function` versions on `Kernel` are available everywhere, including inside task bodies.

### Refactored

- **`validate_deps!` decomposed into focused private helpers** — the method was performing four unrelated validations in one body (orphaned `depends_on` check, undefined dep name check, dep arity check, cycle detection). Each concern is now a dedicated `_`-prefixed private method (`_check_orphaned_deps!`, `_check_undefined_deps!`, `_check_dep_arities!`, `_build_and_sort_graph`). `validate_deps!` is now a sequencer of ~8 lines. Flog score dropped from 87.3 to 24.4.
- **`invoke_command` dispatch helpers made private with descriptive names** — the dispatch hook was decomposed into focused helpers. Those helpers (`acquire_run_token`, `run_deps_for`, `run_dep_group`, `signal_done`, `run_dep`) are now declared `private` on `Asgard::Base` rather than wrapped in `no_commands`. The `_` prefix was dropped — the underscore convention is reserved for gem-owned methods on `Tasks`; `private` is sufficient to exclude instance methods from Thor's command registry. `invoke_command` itself stays in `no_commands` so Thor does not warn about an undescribed public method.

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
- **`default_task` behaviour documented** — `docs/tasks.md` now notes that running `asgard` with no arguments displays the help message when `default_task` is not set.
- **`loki_up` scope clarified in docs** — `docs/task-files.md` and `docs/api.md` now make explicit that `loki_up` locates any file by name, not just `.loki` files, with examples for `.env` and `VERSION`. The `dotenv loki_up(".env") || ".env"` pattern is shown as the canonical way to load a `.env` file from any subdirectory.
- **`examples/.loki`** — updated to use explicit `import "*.loki"` (sibling files) and `import "subdir/import_demo.loki"` (subdirectory file), with comments explaining `import`, `import_up`, and `loki_up`.

### Added (continued)

- **`--doctor` built-in CLI flag** — diagnoses `.loki` resolution, import chains, and task definitions for the current directory, then exits. Handled directly in `Asgard.run!` before the `.loki` file is loaded (same pattern as `--version`), so it keeps working in exactly the situations that would otherwise abort the whole process: a broken `.loki` file, a circular or undefined dependency, or a task silently redefined by a later `def`. Backed by the new `Asgard::Doctor` class. The report includes a "Tasks by file" listing: every command grouped by the file it's defined in, printed as `relative/path:line` so an editor can jump straight to it. A task name defined at more than one location gets every definition annotated inline — the earlier one(s) as `OVERRIDDEN by <file>:<line> — never callable`, the winning (last) one as `active — redefines <file>:<line>` — replacing the old flat "Tasks#x redefined" summary line with an annotation right where the problem is. See [API Reference](docs/api.md#asgarddoctor).
- **Flay and Reek quality gates** — `flay_check` checks for structural code duplication (mass ≥ 150); `reek` checks code smells. Both run as part of `quality` alongside `test`, `rubocop`, and `flog_check`. A `.reek.yml` tunes several detectors to this codebase's conventions (no doc-comment requirement, short variable names, disabled `TooManyStatements`, etc), plus per-method `exclude:` entries (generated with `reek --todo` and hand-curated) that grandfather specific reviewed smells at specific methods — precise enough that a genuinely new smell still fails the gate even at an already-reviewed method, unlike a per-file count.
- **`test_verbose` task** — runs the test suite with Minitest's verbose (`-v`) output.
- **Colorized quality gate summary** — `quality`'s final report now prints a green/red PASS/FAIL badge per gate plus a passed/failed tally, via a shared `print_quality_summary` helper.
- **`console` task** — opens an IRB console with the gem loaded (`bin/console` if present, otherwise `bundle exec irb`).
- **`git.loki`** — per-repo git tasks (`push`, `pull`, `fetch`), imported from `.loki`.

### Changed (continued)

- **`release` task** now prompts for confirmation (`Release asgard vX.Y.Z to RubyGems? [y/N]`) unless `-y`/`--yes` is passed, before tagging and pushing.

### Fixed (continued)

- **`bin/asgard` could silently run the wrong `asgard` version** — the executable did `require "asgard"`, which (without `bundle exec`) is resolved by RubyGems independently of where the script itself lives, so it could load a separately-installed gem version instead of this repo's own `lib/`. Changed to `require_relative "../lib/asgard"` so the executable always loads the library that ships alongside it, regardless of what else is installed.

### Added (continued 2)

- **`SKIP` and `WARN` quality-gate statuses** — alongside `PASS`/`FAIL`. Both are non-blocking (`quality` only aborts on `FAIL`); `SKIP` is for a required external tool that isn't installed, `WARN` is for a check that ran successfully but has non-blocking suggestions. `print_quality_summary` renders all four with distinct colored badges and a combined tally.
- **`typos_check` / `typos_fix` tasks** — spell-checking via the external `typos` CLI (`brew install typos-cli`, not a gem dependency). `typos_check` writes full findings to `typos_output.txt` and participates in `quality`. If `typos` isn't installed, the gate prints a one-line notice recommending `brew install typos-cli` and reports `SKIP` rather than failing.
- **`fasterer_check` task** — runs the `fasterer` gem (new dev dependency) against `lib/`, reporting performance-idiom suggestions as `WARN` (non-blocking) — these are suggestions on working code, not correctness problems.
- **`asgard tree` now shows the project header/footer** — `Base#tree` wraps Thor's built-in command tree the same way `Base#help` already wraps the command list, so both example outputs are consistent.
- Every quality gate (`test_check`, `rubocop_check`, `flog_check`, `flay_check`, `reek_check`, `typos_check`, `fasterer_check`, `bundler_audit_check`) now writes its full detailed output to a `<gate>_output.txt` file at the repo root (gitignored via `*_output.txt`) and prints only a one-line summary to stdout — full detail stays on disk without cluttering the terminal.

### Changed (continued 2)

- **`Asgard::Base` and `Asgard::Doctor` split into focused mixins** — `Asgard::Base` (31 methods) is now `Registry`, `DependencyGraph`, `TaskDSL`, and `Dispatch` (`lib/asgard/base/*.rb`), with `method_added`/`header`/`footer`/`help`/`tree` remaining directly on the class as the orchestrator. `Asgard::Doctor` (19 methods) is now `TaskSections` and `Report` (`lib/asgard/doctor/*.rb`), with the diagnostic flow (`run`, `report_markers`, `load_chain`, etc.) staying on the class itself. Purely a file-organization change — behavior, `asgard help`/`asgard --doctor` output, and the public API are unchanged. Drops Reek's `TooManyMethods`/`TooManyInstanceVariables` warnings on both classes to zero.
- **Reek grandfathering made precise** — replaced the per-file smell-count baseline (`.quality/reek_baseline.txt`, the `reek_baseline` task) with per-method, per-detector `exclude:` entries in `.reek.yml` itself, generated via `reek --todo` and hand-curated. Unlike a count, this still catches a genuinely new smell at an already-reviewed method, without relying on the file's total count staying the same. The `reek_baseline` and `ensure_quality_dir` tasks and the `.quality/` directory have been removed as no longer needed.

### Added (continued 3)

- **`depends_on` accepts a Proc/lambda in addition to a fixed list** — a sole callable defers resolution to `validate_deps!` (once, right after every `.loki` file has loaded) instead of resolving immediately when `depends_on` itself is evaluated. This solves the "load order matters" problem for a dependency list that can't be known upfront — e.g. "every task whose name ends in `_check`," discovered across several files including ones imported conditionally (`import "quality_rails.loki" if defined?(Rails)`). The Proc must return the same shape the splat form would receive (an array of stages, each a `Symbol` or `Array`); it's written directly in the class body, so it lexically captures that class as `self` and can call `all_commands` bare. A Proc that raises is re-raised as `Asgard::Error` naming the task it was declared for; a Proc that resolves to an undefined task or a cycle is still caught by the existing startup validation, since the resolved result is checked exactly like a plain array. See [Dynamic Dependencies](docs/dependencies.md#dynamic-dependencies-proc-form).
- **`bundler_audit_check` task** — runs `bundle-audit check --update` against `Gemfile.lock` (new dev dependency `bundler-audit`); reports `FAIL` on any known vulnerability, since this is a security gate, not a suggestion.
- **`quality_rails.loki`** — imported by `.loki` only when `Rails` is defined; currently ships `brakeman_check`, a Rails security-scan example. Needs no wiring into `quality`'s dependency list — `quality`'s `depends_on` Proc discovers it automatically once it's loaded.

### Changed (continued 3)

- **`test`, `rubocop`, `reek` renamed to `test_check`, `rubocop_check`, `reek_check`** — for consistency with the other gates, all of which already ended in `_check`. This convention is what makes automatic discovery possible: `quality`'s `depends_on` Proc finds every task whose name matches `_check\z` rather than naming them one by one.

### Removed (continued)

- **`dagwood` runtime dependency** — replaced by stdlib `TSort` for the one thing it was still doing (cycle detection); the parallel-execution plan itself was already derived directly from `depends_on`'s stage list, not from a rebuilt DAG. `_build_dep_graph` (dead code — its return value was already unused) is deleted along with the gemspec entry.

### Changed (continued 4)

- **`validate_deps!` cycle detection now uses stdlib `TSort`** instead of `Dagwood::DependencyGraph#order` — a private `Graph` `Struct` (`edges` member, `include TSort`) owns the task→dependency Hash and the traversal, raising `TSort::Cyclic` on a cycle exactly as before (converted to `Asgard::CircularDependencyError`). `run_deps_for` no longer round-trips through a rebuilt DAG on every dispatch — it iterates `_deps[target]`'s stage groups directly, which is already the parallel-execution plan `depends_on` built.

### Fixed (continued 2)

- **`quality.loki`'s parallel `*_check` tasks raced on shared instance state** — each `*_check` task wrote its pass/fail status to an ivar on `self` (`@test_result`, `@rubocop_result`, ...) from inside a `Thread.new` spawned by the same parallel-dependency group — an unsynchronized write across threads that MRI's GVL happens to hide today but would not on JRuby/TruffleRuby. Fixed at the framework level: `Dispatch#run_dep_group` now collects each task's own return value into a `Hash` (via `Thread#value`), `run_deps_for` merges per-stage results, and a new `dep_result`/`dep_results` instance API (backed by `Thread.current`, not `self`) hands them to the task body that depends on them. `quality.loki` and `quality_rails.loki`'s `*_check` tasks now return their status as a plain value instead of writing to an ivar; `quality` reads `dep_result(name)` instead of `instance_variable_get`.

### Added (continued 4)

- **`examples/bad.loki`** — a worked demonstration of the race the fix above addresses: 4 parallel workers read-modify-write a shared `@hits` counter directly (the anti-pattern `quality.loki` used to have), reliably losing updates. Kept as a contrast example for what `dep_result`/`dep_results` is for.

### Added (continued 5)

- **`sh(script, exec: true)`** — hands the command the asgard process itself via `Kernel.exec` instead of forking. For a task's final, long-running command (a dev server, a REPL) this replaces the ruby process outright, so nothing sits resident in memory behind it and Ctrl-C is handled directly by the command instead of unwinding back through asgard. `doc_tasks.loki`'s `doc_server` task (`sh "mkdocs serve", exec: true`) is the motivating example. See [Shell Helpers](docs/shell.md#handing-off-with-exec).
- **`bootstrap` and `env_info` tasks in `kitchen_sink.loki`** — demonstrate `sh` with a multi-line heredoc (routed through `bash -c`) and a single-line command, respectively.

### Fixed (continued 3)

- **Ctrl-C during a running `sh` command printed a raw `Interrupt` backtrace** — SIGINT hits the whole foreground process group, so asgard's own ruby process raised `Interrupt` independently of whatever the shelled-out command did with the signal, and it went uncaught, unwinding through Thor and printing a stack trace before exiting. `Asgard.run!` now rescues `Interrupt` and exits with the conventional 130 status.

### Added (continued 6)

- **`depends_on` accepts a block in addition to a Proc/lambda** — `depends_on { ... }` (or `depends_on do ... end` for a block spanning multiple statements) defers resolution to `validate_deps!` exactly like the existing sole-Proc/lambda form; the two are interchangeable. `depends_on` still accepts task arguments *or* a block, never both — combining them raises `Asgard::Error`. See [Dynamic Dependencies](docs/dependencies.md#dynamic-dependencies-proc-block-form).
- **The resolved Proc/lambda/block result is now shape-validated** — once `validate_deps!` calls it, the return value must be an `Array` of stages, each a `Symbol`/`String` (sequential) or an `Array` of `Symbol`/`String` (parallel group), nested no deeper than that. A bad shape (wrong type, an invalid stage, a non-Symbol/String leaf, or nesting more than one level deep) now raises `Asgard::Error` naming the task and the offending value, instead of failing later with an opaque `NoMethodError`.
- **`examples/depends_on_block/good/` and `examples/depends_on_block/bad/`** — two self-contained example projects (each its own `.loki` root, isolated from the main `examples/` tree) demonstrating the block form: `good/` covers single-line `{ ... }`, `do...end`, and a mixed sequential+parallel shape; `bad/` demonstrates the double-wrapped-array mistake that the new shape validation catches, with the exact `Asgard::Error` message it produces.

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

[0.3.0]: https://github.com/MadBomber/asgard/compare/v0.2.2...HEAD
[0.2.0]: https://github.com/MadBomber/asgard/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/MadBomber/asgard/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/MadBomber/asgard/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/MadBomber/asgard/releases/tag/v0.1.0
