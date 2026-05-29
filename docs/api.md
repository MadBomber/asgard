# API Reference

This page documents the public Ruby API for the Asgard gem. Most users interact with Asgard through the CLI and the task DSL — this page is primarily useful when integrating Asgard into tooling or extending it programmatically.

---

## `Asgard` Module Methods

These class methods are defined on the `Asgard` module itself.

| Method | Signature | Description |
|---|---|---|
| `run!` | `Asgard.run!(argv)` | Main entry point. Finds `.loki`, loads all task files, validates the dependency graph, and dispatches via Thor. Handles its own errors: missing `.loki` and circular dependencies both produce a clean one-line message and `exit 1`. |
| `find_task_file` | `Asgard.find_task_file → String, nil` | Searches `Dir.pwd` and each ancestor directory for a `.loki` file. Returns the absolute path string of the first match, or `nil` if none is found. |
| `load_loki` | `Asgard.load_loki(dir)` | Loads all `*.loki` files in `dir` alphabetically, excluding `.loki` itself. Called by `run!` only when `--auto-load` is present in `argv`. |

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

## `Asgard::Base` DSL Class Methods

`Asgard::Base` is a `Thor` subclass that provides the task DSL. It is the superclass of `Tasks`. All DSL methods are class methods (called in the class body).

| Method | Signature | Description |
|---|---|---|
| `depends_on` | `depends_on(*tasks)` | Declare prerequisites for the next `def`. Bare symbols run sequentially; arrays within the splat run as a parallel group. |
| `var` | `var(name, value = nil, &block)` | Declare a named variable. If `value` responds to `call` (lambda/proc) or a block is given, the value is computed lazily on first access. Accessible in task bodies as a method. |
| `import` | `import(mod)` | Include a module into the current class (thin alias for `include`). |
| `dotenv` | `dotenv(path = ".env")` | Load the specified `.env` file into `ENV` using the dotenv gem. Silently skipped if the file does not exist. Called at class-load time. |
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
| `_version` | private task method | Implements `--version`. Prints `Asgard::VERSION` and exits. Registered via `map "--version" => :_version`. Uses `_` prefix convention. |
| `debug?` | private instance method | Returns `$DEBUG`. Available in all task bodies and subcommand classes that inherit from `Tasks`. |
| `verbose?` | private instance method | Returns `$VERBOSE`. Available in all task bodies and subcommand classes that inherit from `Tasks`. |
| `--auto-load` | CLI flag (consumed by `run!`) | Triggers loading of all `*.loki` files before the main `.loki` and the requested task. Consumed by `run!` before Thor dispatch. |

---

## `Asgard::Base` Internal Class Methods

These are implementation details exposed for extensibility. Prefer the DSL methods above in normal use.

| Method | Description |
|---|---|
| `_deps` | Hash mapping task name symbols to their stage arrays. Set by `depends_on` + `method_added`. |
| `_vars` | Hash mapping var name symbols to their static values or callables. |
| `_ran_tasks` | `Set` of task name symbols that have already run in the current invocation. |
| `_ran_mutex` | `Mutex` protecting `_ran_tasks` for thread-safe deduplication. |
| `_build_dep_graph(stages)` | Translates the stage array (from `_deps`) into a Dagwood-compatible hash. |

---

## `invoke_command` Hook

`Asgard::Base` overrides Thor's `invoke_command` to implement dependency resolution and deduplication:

1. Sets `$DEBUG` / `$VERBOSE` from `options` if the corresponding flags are present.
2. Checks `_ran_tasks` — skips if this task has already run.
3. Marks the task as ran.
4. Resolves dependency stages from `_deps`, builds the Dagwood graph, and executes groups (parallel groups in threads, sequential groups one at a time).
5. Calls `command.run(self, *args)` to execute the task itself.

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
