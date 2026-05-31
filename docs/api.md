# API Reference

This page documents the public Ruby API for the Asgard gem. Most users interact with Asgard through the CLI and the task DSL — this page is primarily useful when integrating Asgard into tooling or extending it programmatically.

---

## `Asgard` Module Methods

These class methods are defined on the `Asgard` module itself.

| Method | Signature | Description |
|---|---|---|
| `run!` | `Asgard.run!(argv)` | Main entry point. Finds `.loki`, loads all task files, validates the dependency graph, and dispatches via Thor. Handles its own errors: missing `.loki` and circular dependencies both produce a clean one-line message and `exit 1`. |
| `find_task_file` | `Asgard.find_task_file → Pathname, nil` | Searches `Dir.pwd` and each ancestor directory for a `.loki` file. Returns a `Pathname` of the first match, or `nil` if none is found. |

### `run!` Details

```ruby
Asgard.run!(ARGV)
```

`run!` guards against direct invocation of `_`-prefixed commands before any files are loaded:

```ruby
abort "asgard: unknown command '#{argv.first}'" if argv.first&.start_with?("_")
```

After loading task files, it calls `Tasks.validate_deps!` (circular dependency check) and `Tasks._reset_ran!` (clears per-invocation deduplication state) before starting Thor.

---

## Kernel Methods

These methods are defined as `module_function` on `Kernel` and are therefore available everywhere in Ruby — at the top level of `.loki` files, inside class bodies, and inside task method bodies. No `require` or `include` is needed; they are loaded when `asgard` starts.

| Method | Signature | Returns | Description |
|---|---|---|---|
| `loki_up` | `loki_up(name = ".loki") → Pathname, nil` | `Pathname` or `nil` | Searches `Dir.pwd` and each ancestor directory for a file named `name`. Returns a `Pathname` for the first match, or `nil` if not found. Exact filenames only — does not expand globs. |
| `import` | `import(path) → true, false` | `true` if any file newly loaded | Loads one `.loki` file or a glob of `.loki` files. Relative paths resolve relative to the caller's file (like `require_relative`). Idempotent via `$LOADED_FEATURES`. Raises `ArgumentError` if `path` does not end with `.loki`. Raises `LoadError` if a non-glob path does not exist. |
| `import_up` | `import_up(name = ".loki") → true, false` | `true` if any file newly loaded | Combines `loki_up` and `import`. Walks ancestors to find the file or glob match, then loads it. Returns `false` if nothing is found. |
| `debug?` | `debug? → true, false` | `$DEBUG` | Returns the current value of `$DEBUG`. Set to `true` by `--debug` on the CLI or directly via `$DEBUG = true`. |
| `verbose?` | `verbose? → true, false` | `$VERBOSE` | Returns the current value of `$VERBOSE`. Set to `true` by `--verbose` on the CLI or directly via `$VERBOSE = true`. |
| `env` | `env(name, default = nil) → String, nil` | `ENV` value or default | Fetches an environment variable by symbol or string name. The name is upcased automatically. Raises `KeyError` when the variable is missing and no default is given. |

### `loki_up` Details

Despite the name, `loki_up` is not limited to `.loki` files — it locates any file by walking up the directory tree:

```ruby
loki_up                       # find .loki (the project root marker)
loki_up("gem_tasks.loki")     # find gem_tasks.loki in CWD or any ancestor
loki_up(".env")               # find the nearest .env file up the tree
loki_up("VERSION")            # find a VERSION file in CWD or any ancestor
```

Returns a `Pathname` or `nil`. Does not load the file. `Pathname` is accepted by `import`, `dotenv`, `load`, and standard Ruby file methods — no `.to_s` conversion needed in common usage.

```ruby
if (path = loki_up("gem_tasks.loki"))
  import path          # Pathname accepted directly
end

# Pass the located .env to dotenv — works from any subdirectory
dotenv loki_up(".env") || ".env"
```

### `import` Details

```ruby
import "build.loki"                  # relative — resolved from the calling file's directory
import "/home/shared/gem_tasks.loki" # absolute
import "*.loki"                      # all *.loki in the same directory as the caller
import "../shared/*.loki"            # all *.loki one level up
import "**/*.loki"                   # all *.loki recursively
import Pathname.new("tasks.loki")    # Pathname accepted
```

**Extension requirement:** the path (or glob pattern) must end with `.loki`. Passing any other extension raises `ArgumentError`.

**Glob behaviour:** `Dir.glob` is used for pattern expansion. `*.loki` does not match `.loki` (the dotfile) — Ruby's glob excludes dotfiles from `*` by default. Files are loaded in the order `Dir.glob` returns them (sorted on Ruby ≥ 2.7).

**Idempotency:** each resolved absolute path is checked against `$LOADED_FEATURES` before loading. A file already in `$LOADED_FEATURES` is silently skipped and contributes `false` to the return value.

**Return value:** `true` if at least one file was newly loaded; `false` if all matched files were already loaded or no glob pattern produced any matches.

**Verbose/debug output** (to stderr):
- `verbose?` true — prints each file path as it is loaded
- `debug?` true — also prints a skip message for each already-loaded file

### `import_up` Details

```ruby
import_up                          # find and load .loki
import_up "gem_tasks.loki"         # find and load gem_tasks.loki up the tree
import_up "*.loki"                 # find the nearest ancestor with *.loki files and load them all
```

**Exact name:** delegates to `loki_up` to find the file, then calls `import` with the absolute path. Returns `false` without raising if the file is not found.

**Glob name:** walks ancestor directories manually using `Dir.glob`. Stops at the **first** ancestor that has any matches and loads all of them — it does not continue walking after finding a match. Returns `false` if no ancestor contains matching files.

**Verbose/debug output** (to stderr):
- `verbose?` true — prints `name → /full/path` when a file or directory is found
- `debug?` true — also prints `name not found` when the search comes up empty

---

## `Asgard::Base` DSL Class Methods

`Asgard::Base` is a `Thor` subclass that provides the task DSL. It is the superclass of `Tasks`. All DSL methods are class methods (called in the class body).

| Method | Signature | Description |
|---|---|---|
| `depends_on` | `depends_on(*tasks)` | Declare prerequisites for the next `def`. Bare symbols run sequentially; arrays within the splat run as a parallel group. |
| `dotenv` | `dotenv(path = ".env")` | Load the specified `.env` file into `ENV` using the dotenv gem. Silently skipped if the file does not exist. Called at class-load time. |
| `header` | `header(text)` | Append a line of text shown above the commands list in `asgard help`. Each call adds another line. No-op for per-command help. |
| `footer` | `footer(text)` | Prepend a line of text shown below the options block in `asgard help`. Each call inserts above the previous lines. No-op for per-command help. |
| `no_negate` | `no_negate(*names)` | Suppress `[--no-name]` / `[--skip-name]` help entries for one or more boolean class options. Call after the `class_option` declaration. |
| `sh` | `sh(script, silent: false)` | Instance method. Run a shell command or multiline heredoc. Single-line → `system(script)`; multiline → `system("bash", "-c", script)`. Exits with the command's status on failure. |
| `shebang` | `shebang(interpreter, script, silent: false)` | Instance method. Write `script` to a tempfile and execute it with `interpreter`. See the [Shell Helpers](shell.md) page for the full interpreter table. |
| `validate_deps!` | `Tasks.validate_deps!` | Build and topologically sort the full dependency graph using Dagwood. Raises `Asgard::CircularDependencyError` on cycles. Called by `run!` at startup. |
| `_reset_ran!` | `Tasks._reset_ran!` | Clear the per-invocation task deduplication set. Called by `run!` before dispatching. Thread-safe via Mutex. |

### `depends_on` Argument Shapes

```ruby
depends_on :build                          # single sequential dep
depends_on :clean, :build                  # two sequential deps
depends_on [:lint, :typecheck]             # lint and typecheck run in parallel
depends_on :setup, [:lint, :build], :test  # setup, then lint+build concurrently, then test
```

---

## `Tasks` Built-ins

`Tasks` is pre-defined by the gem as `class Tasks < Asgard::Base`. It adds the following:

| Item | Type | Description |
|---|---|---|
| `class_option :debug` | class option | `--debug` flag. Sets `$DEBUG = true` before any task runs. Boolean, default `false`. |
| `class_option :verbose` | class option | `--verbose` flag. Sets `$VERBOSE = true` before any task runs. Boolean, default `false`. |
| `class_option :version` | class option | `--version` flag. Handled by `Asgard.run!` before the `.loki` file is loaded — prints `Asgard::VERSION` and exits. `no_negate :version` suppresses the `[--no-version]` / `[--skip-version]` help entries. |
| `debug?` | Kernel module function | Returns `$DEBUG`. Available everywhere via `Kernel`. |
| `verbose?` | Kernel module function | Returns `$VERBOSE`. Available everywhere via `Kernel`. |

---

## `Asgard::Base` Internal Class Methods

These are implementation details exposed for extensibility. Prefer the DSL methods above in normal use.

| Method | Description |
|---|---|
| `_deps` | Hash mapping task name symbols to their stage arrays. Set by `depends_on` + `method_added`. |
| `_done` | `Set` of task name symbols that have completed in the current invocation. |
| `_running` | `Set` of task name symbols currently executing (started but not yet finished). |
| `_cond` | Hash of `ConditionVariable` objects keyed by task name; threads wait here when a dep is in-flight. |
| `_ran_mutex` | `Mutex` protecting `_done`, `_running`, and `_cond` for thread-safe access. |
| `_build_dep_graph(stages)` | Translates the stage array (from `_deps`) into a Dagwood-compatible hash. |

---

## `invoke_command` Hook

`Asgard::Base` overrides Thor's `invoke_command` to implement dependency resolution and deduplication:

1. Sets `$DEBUG` / `$VERBOSE` from `options` if the corresponding flags are present.
2. Tries to acquire a run token (`acquire_run_token`): if the task is already in `_done`, returns immediately (skip); if it is in `_running`, waits on the `_cond` ConditionVariable until it finishes, then returns (skip); otherwise adds the task to `_running` and continues.
3. Resolves dependency stages from `_deps`, builds the Dagwood graph, and executes groups (parallel groups in threads, sequential groups one at a time).
4. Calls `command.run(self, *args)` to execute the task itself.
5. In an `ensure` block, adds the task to `_done` and broadcasts on its `_cond` to wake any waiting threads.

---

## Error Classes

| Class | Superclass | Description |
|---|---|---|
| `Asgard::Error` | `StandardError` | Base error class for all Asgard errors. |
| `Asgard::CircularDependencyError` | `Asgard::Error` | Raised by `validate_deps!` when a cycle is detected in the dependency graph. `run!` catches this and calls `abort` with a clean message. |

```ruby
begin
  Asgard.run!(ARGV)
rescue Asgard::CircularDependencyError => e
  # This is already handled inside run! — you only need this
  # if you call validate_deps! directly in your own tooling.
  abort "circular dependency: #{e.message}"
end
```

---

## Dependencies

| Gem | Version | Purpose |
|---|---|---|
| [thor](https://github.com/rails/thor) | `~> 1.0` | CLI framework; provides the full task DSL |
| [dagwood](https://rubygems.org/gems/dagwood) | `~> 1.0` | DAG library for dependency graph resolution and topological sort |
| [dotenv](https://github.com/bkeepers/dotenv) | `~> 3.0` | `.env` file loading |

---

## Ruby Version Requirement

Asgard requires **Ruby >= 3.2.0**.
