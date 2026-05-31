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
asgard test
asgard quality
asgard release
```

Single test: `ruby -Ilib:test test/test_asgard.rb`

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
2. Resolve `@_deps` stages → `_build_dep_graph` → `Dagwood::DependencyGraph#parallel_order`
3. For each parallel group: spawn one thread per task, join; single-task groups run inline
4. Execute the target task

**`_build_dep_graph(stages)`** converts stages to a DAG hash:
- `[[:a], [:b, :c], [:d]]` → `{ a: [], b: [:a], c: [:a], d: [:b, :c] }`

### Dependency Resolution

Dagwood topologically sorts the DAG and returns parallel groups. The thread-safe deduplication (`_ran_tasks` Set + Mutex) ensures each task runs exactly once even when multiple tasks share a common dependency.

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

All tests are in `test/test_asgard.rb` (one file, ~11 named classes). SimpleCov minimum is 95%; the Rakefile configures this with a prelude that loads coverage before the library.

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
