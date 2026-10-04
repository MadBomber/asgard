# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Asgard Is

Asgard is a Ruby task runner. Users define tasks in `.loki` files by reopening the pre-defined `Tasks` class. The name is intentional: Thor handles the CLI, Asgard is where tasks live, and Loki (the `.loki` file) holds all the tricks.

## Commands

```bash
bundle install
asgard                 # default task: quality (every *_check gate in parallel)
asgard test_check      # run the test suite (enforces 95% SimpleCov coverage)
asgard test_verbose    # same, verbose output
asgard rubocop_check   # one gate on its own; also flog_, flay_, reek_, exhale_, archspec_check ...
asgard build           # build .gem into pkg/
asgard install         # build and install locally
asgard release         # quality gate, then push to RubyGems
asgard tree            # every available task
```

There is no Rakefile. Asgard is its own task runner: the tasks that a Rakefile would
hold live in the `.loki` files at the repo root (`quality.loki`, `gem_tasks.loki`,
`git.loki`, `doc_tasks.loki`), imported by `.loki`.

Whole suite (one process, so SimpleCov sees everything): `ruby -Ilib:test -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }'`

Single file: `ruby -Ilib:test test/test_asgard.rb` (a single file alone will fall below the coverage minimum)

## Architecture

### Entry Point Flow

`bin/asgard` → `Asgard.run!(ARGV)` (`lib/asgard.rb`):
1. Walk CWD + ancestors for `.loki` (marker only, not a task file)
2. Load `.loki` — any sibling `*.loki` files are loaded only if `.loki` calls `import`
3. `Tasks.validate_deps!` — build full dep graph, raise `CircularDependencyError` if cyclic
4. `Tasks._reset_ran!` — clear execution tracking
5. `Tasks.start(argv)` — Thor dispatches the command

### Core Classes

| File | Role |
|------|------|
| `lib/asgard/base.rb` | DSL engine; inherits Thor, includes Shell |
| `lib/asgard/shell.rb` | `sh` / `shebang` helpers |
| `lib/asgard/tasks.rb` | `class Tasks < Asgard::Base` — the convention class users reopen; also holds gem-owned built-in tasks |
| `lib/asgard/schedule.rb` | `Asgard::Schedule` — the `schedule` DSL registry; requires the files below |
| `lib/asgard/schedule/declaration.rb` | Pure declaration validation + the backend API contract |
| `lib/asgard/schedule/launchd.rb`, `systemd.rb`, `windows.rb`, `cron.rb` | Platform backends (cron only via `ASGARD_SCHEDULER=cron`); shell out through an injectable runner |
| `lib/asgard/schedule/commands.rb` | `asgard schedule ...` subcommands (registered as `_schedule`, mapped to `schedule`) |

### Naming Convention for Gem-Owned Methods

Any task or method defined by Asgard itself inside `Tasks` (i.e. not by the user's `.loki` files) must be prefixed with `_`. This distinguishes built-in gem behavior from user-defined tasks and prevents naming collisions.

```ruby
# lib/asgard/tasks.rb — gem-owned built-ins use _ prefix
class Tasks < Asgard::Base
  desc "--version", "Show version"
  map "--version" => :_version
  def _version
    puts Asgard::VERSION
    exit
  end
end
```

`method_added` in `Base` already skips `_`-prefixed methods when attaching dependency metadata, so built-ins are naturally excluded from the dependency graph.

Do not define `_`-prefixed methods in user `.loki` files — that namespace is reserved for the gem.

### Duplication Contract (`contract/`)

`exhale dry` (run by `asgard exhale_check`) fails on duplicated code unless the Contract keeps it. `contract/schedule_backend/duplication.md` declares the four scheduler backends (`Launchd`, `Systemd`, `Cron`, `Windows`) parallel on purpose: they share shapes (`initialize`, `run!`, `installed_entries`, `installed_directory`) but stay independent so a fix for one scheduler never touches another. Anything platform-neutral belongs in `declaration.rb`, not a shared base class. A clause naming code that no longer exists, or keeping nothing, fails the gate, so update the Contract when a backend is renamed or removed.

`Archspec.rb` (`asgard archspec_check`) enforces the same obligations statically: each backend is its own component that must implement the backend API, may not reference `Open3` or call `system`/`spawn`/`capture*`, and may not reference another backend or the CLI. Two cycles are deliberately excluded from `no_cycles` and documented there (Tasks and the schedule CLI; the backend factory in `declaration.rb` and the backends). Add a new backend to the `BACKENDS` hash in `Archspec.rb` and to the Contract.

### DSL Mechanics (`lib/asgard/base.rb`)

**`depends_on`** stores stages in `@_pending_deps`. On `method_added`, those stages are popped and stored in `@_deps[method_name]`. Bare symbols are sequential stages; arrays within a `depends_on` call are parallel stages:

```ruby
depends_on :a, [:b, :c], :d   # stages: [[:a], [:b, :c], [:d]]
```

**`invoke_command`** (Thor dispatch hook):
1. Atomically check `@_ran_tasks` Set (with `@_ran_mutex`); return early if already run
2. Look up `@_deps[target]` — already the parallel-group stage list `depends_on` built
3. For each stage group: spawn one thread per task, join; single-task groups run inline
4. Execute the target task

### Dependency Resolution

`depends_on`'s stage list (`[[:a], [:b, :c], [:d]]`) *is* the parallel-execution plan — no separate graph library is needed to run it. Cycle detection is a separate concern, handled once in `validate_deps!` via stdlib `TSort` over the full `@_deps` graph (raises `TSort::Cyclic`, converted to `Asgard::CircularDependencyError`). The thread-safe deduplication (`_ran_tasks` Set + Mutex) ensures each task runs exactly once even when multiple tasks share a common dependency.

### Shell Helpers

- `sh(script, silent: false)` — single-line strings use `system(script)`; multi-line strings pipe through `bash -c`; exits with the command's status on failure
- `shebang(interpreter, script)` — writes script to a tempfile and executes with the named interpreter (`:python3`, `:node`, `:ruby`, `:perl`, `:bash`, etc.)

### Kernel Methods

Asgard adds the following `module_function` methods to `Kernel`, making them available everywhere in `.loki` files without any prefix or require:

| Method | Description |
|--------|-------------|
| `env(name, default = nil)` | Fetch a system environment variable by symbol or string; name is upcased automatically. Raises `KeyError` when missing and no default given. |
| `loki_up(name = ".loki")` | Walk CWD and ancestors for a file by name; returns absolute path or `nil`. |
| `import(path)` | Load a `.loki` file or glob of `.loki` files, idempotently. |
| `import_up(name = ".loki")` | Combine `loki_up` and `import` — find and load in one call. |
| `debug?` | Returns `$DEBUG`. |
| `verbose?` | Returns `$VERBOSE`. |

## Testing

Engine tests are in `test/test_asgard.rb`; scheduling tests are in `test/test_schedule.rb`, which uses a `FakeRunner` (records launchctl/systemctl argv), a `FakeCrontab` and a `FakeSchtasks` so every backend tests on any platform. SimpleCov minimum is 95%, configured in `test/test_helper.rb`, which starts coverage before requiring the library; `asgard test_check` (quality.loki) loads every test file in one process so coverage covers the whole suite.

Key test patterns: tests frequently subclass `Asgard::Base` directly (not `Tasks`) to test the engine in isolation, and use `capture_io` for output assertions.

## The `.loki` Format

A `.loki` file is plain Ruby that reopens `Tasks`:

```ruby
class Tasks
  @@gem_name ||= "asgard".freeze

  desc "test", "Run tests"
  def test = sh "ruby -Ilib:test test/test_asgard.rb"

  depends_on :test
  desc "build", "Build the gem"
  def build = sh "gem build #{@@gem_name}.gemspec"
end
```

Only `.loki` is loaded by default. The bare `.loki` file is the project root marker and always controls what else gets loaded — call `import "*.loki"` (or any glob/path) at the top to pull in sibling task files.
