# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Asgard Is

Asgard is a Ruby task runner. Users define tasks in `.loki` files by reopening the pre-defined `Tasks` class. The name is intentional: Thor handles the CLI, Asgard is where tasks live, and Loki (the `.loki` file) holds all the tricks.

## Commands

```bash
bundle install
bundle exec rake test          # run tests (enforces 95% SimpleCov coverage)
bundle exec rake quality       # test + flog complexity check
bundle exec rake build         # build .gem into pkg/
bundle exec rake install       # install locally

# or use the gem's own .loki file:
asgard test_check
asgard quality
asgard release
```

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
| `lib/asgard/schedule/launchd.rb`, `systemd.rb` | Platform backends; shell out through an injectable runner |
| `lib/asgard/schedule/commands.rb` | `asgard schedule ...` subcommands (registered as `_schedule`, mapped to `schedule`) |
| `lib/asgard/watch.rb` | `Asgard::Watch` — the `watch` DSL registry; requires the files below |
| `lib/asgard/watch/declaration.rb` | Pure declaration validation: globs to directories plus `only:` Regexps, events, ignores |
| `lib/asgard/watch/changes.rb` | `Asgard::Changes` (the trigger's path lists) and `Watch.filter_events` |
| `lib/asgard/watch/spawn.rb` | Pure: the frozen, Ractor-shareable description of one task run (argv, whitelisted env) |
| `lib/asgard/watch/worker.rb` | One Ractor per task; runs its triggers serially and reports each spawn and exit |
| `lib/asgard/watch/reporter.rb`, `dispatcher.rb` | Single writer of log and entry records; batch routing to worker queues |
| `lib/asgard/watch/state.rb`, `daemon.rb` | Pidfile, log and records under XDG state; the foreground `watcher run` process |
| `lib/asgard/watch/commands.rb` | `asgard watcher ...` subcommands (registered as `_watcher`, mapped to `watcher`) |

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

- `shebang(name, script, silent: false, exec: false)` — writes the script to a tempfile and runs it with the shell registered as `name` in `Tasks.shells` (`name => { path:, args:, ext: }`); an unregistered name runs as itself from `PATH` with `.tmp`; a missing executable prints the name and exits 127; `exec: true` unlinks the tempfile and execs on `/dev/fd/N`
- `shebang(script, ...)` with no name, and `sh(script, ...)` — run the `default_shell` (`:bash` until a `.loki` calls `default_shell :name`); one line or many take the same path (issue #1); both return `true`
- `shell(name, path, args: nil, ext: nil)` — class-level DSL that registers a shell; `path` is Shellwords-split, first word is the executable, the rest precede `args:`; `ext:` defaults by executable basename

### Kernel Methods

Asgard adds the following `module_function` methods to `Kernel`, making them available everywhere in `.loki` files without any prefix or require:

| Method | Description |
|--------|-------------|
| `env(name, default = nil)` | Fetch a system environment variable by symbol or string; name is upcased automatically. Raises `KeyError` when missing and no default given. |
| `changes` | The `Asgard::Changes` a watcher trigger passed in (`modified`, `added`, `removed`, `all`, `empty?`); every list is empty when the task is run by hand. |
| `loki_up(name = ".loki")` | Walk CWD and ancestors for a file by name; returns absolute path or `nil`. |
| `import(path)` | Load a `.loki` file or glob of `.loki` files, idempotently. |
| `import_up(name = ".loki")` | Combine `loki_up` and `import` — find and load in one call. |
| `debug?` | Returns `$DEBUG`. |
| `verbose?` | Returns `$VERBOSE`. |

## Testing

Engine tests are in `test/test_asgard.rb`; scheduling tests are in `test/test_schedule.rb`, which uses a `FakeRunner` (records launchctl/systemctl argv) so both backends test on any platform. Watcher tests are in `test/test_watcher.rb`: pure functions directly, the worker and reporter loops in threads with recording stand-ins, and a few real-process tests (a real Ractor worker, a real daemon with a fake Listen, one real Listen run) with no mocks. SimpleCov minimum is 95%; the Rakefile configures this with a prelude that loads coverage before the library.

Key test patterns: tests frequently subclass `Asgard::Base` directly (not `Tasks`) to test the engine in isolation, and use `capture_io` for output assertions.

## The `.loki` Format

A `.loki` file is plain Ruby that reopens `Tasks`:

```ruby
class Tasks
  @@gem_name ||= "asgard".freeze

  desc "test", "Run tests"
  def test = sh "bundle exec rake test"

  depends_on :test
  desc "release", "Build and release"
  def release = sh "bundle exec rake release"
end
```

Only `.loki` is loaded by default. The bare `.loki` file is the project root marker and always controls what else gets loaded — call `import "*.loki"` (or any glob/path) at the top to pull in sibling task files.
