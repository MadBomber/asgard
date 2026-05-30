# Task Files

Asgard uses a convention-based file discovery system. A hidden `.loki` file marks the project root; `*.loki` files in the same directory contain tasks that are loaded on demand via `--auto-load`.

---

## The `.loki` Root Marker

When you run `asgard`, it searches for a `.loki` file starting in the current working directory and walking upward through parent directories until it finds one or reaches the filesystem root. The first `.loki` file found marks the project root.  It may also contain the main task definitions for the project.

This means you can run `asgard` from any subdirectory of your project and it will find your tasks:

```
myproject/
  .loki         ← found regardless of which subdirectory you're in
  src/
    app/
      # asgard still works from here
```

!!! note
    The `.loki` file can be completely empty. Its presence alone is sufficient to mark the project root. If it is empty and you have `*.loki` files, you must pass `--auto-load` when running `asgard` — otherwise Asgard has nothing to do.

---

## Loading `*.loki` Files with `--auto-load`

By default, `asgard` only loads `.loki`. To also load `*.loki` files, pass `--auto-load`:

```bash
asgard --auto-load <task>
```

When `--auto-load` is active, Asgard loads all files matching `*.loki` in the same directory in alphabetical order before loading `.loki`. Each file typically reopens `class Tasks` to add more tasks. The `*.loki` glob specifically excludes `.loki` (note the leading dot) — the entry point is always loaded last.

**Load order when `--auto-load` is passed:**

1. All `*.loki` files alphabetically (e.g., `build.loki`, `deploy.loki`, `test.loki`)
2. `.loki` itself (the entry point)

This means any tasks, classes, or variables defined in `*.loki` files are available when `.loki` runs.

### Task Name Overloading

Because all `*.loki` files reopen the same `class Tasks`, it is possible — by accident or by design — for two files to define a method with the same name. This is **task overloading**. Ruby's class reopening semantics apply: the last definition loaded wins, silently replacing the earlier one.

Three things are overwritten when a task name is reused:

| What | Effect |
|---|---|
| `def method_name` | The Ruby method body — the earlier implementation is gone |
| `desc` metadata | Thor registers the new usage/description string, discarding the old one |
| `depends_on` stages | `method_added` captures the pending deps for the new definition; the earlier dep chain is replaced |

**Accidental overloading** is a silent bug. If `build.loki` and `ci.loki` both define `def build`, only the alphabetically-later file's version runs — with no warning. Keep task names unique across files, or move shared tasks into a dedicated file loaded first.

!!! warning
    There is no runtime error when a task is overloaded. If a task is not behaving as expected, check whether another `*.loki` file defines the same method name and loads after it.

**Intentional overloading** lets you extend or wrap a task defined in an earlier file. Use `alias_method` inside a `no_commands` block to preserve the original implementation under a private name, then redefine the task to call it:

```ruby
# build.loki  (loaded first)
class Tasks
  desc "Compile the project"
  def build
    sh "rake build"
  end
end
```

```ruby
# postbuild.loki  (loaded after build.loki, alphabetically)
class Tasks
  # Preserve the original under a private name before overwriting it.
  no_commands { alias_method :_build_original, :build }

  desc "Compile the project and copy assets"
  def build
    _build_original          # runs the original sh "rake build"
    sh "cp -r dist/ public/" # adds post-build step
  end
end
```

`no_commands` prevents `_build_original` from appearing as a CLI command. The aliased method retains the original's full body including any `sh` calls, `var` access, and private helper calls.

!!! tip
    The `_` prefix on the alias name (`_build_original`) follows Asgard's convention for non-user-facing methods and reinforces that it is an implementation detail, not a task to be invoked directly.

!!! warning "Prefer `depends_on` over intentional overloading"
    Using `alias_method` to bolt post-task behaviour onto an existing task is a code smell. It is fragile (load-order dependent), obscures intent, and makes the dependency chain invisible to Asgard's cycle-detection and deduplication logic.

    The idiomatic Asgard solution is to express the relationship explicitly with `depends_on`:

    ```ruby
    # build.loki
    class Tasks
      desc "Compile the project"
      def build = sh "rake build"

      desc "Copy build output to public/"
      def copy_assets = sh "cp -r dist/ public/"

      depends_on :build, :copy_assets
      desc "Compile and copy assets"
      def build_all; end
    end
    ```

    This approach is transparent, testable, and benefits from Asgard's deduplication — `build` will never run twice even if multiple tasks declare it as a dependency.

---

## Single File Layout

The simplest structure: all tasks in `.loki`, nothing else:

```
myproject/
  .loki
```

```ruby
# .loki
class Tasks
  var :app, "myapp"

  desc "Compile the project"
  def build = sh "rake build"

  desc "Run the test suite"
  def test = sh "rake test"

  desc "Build and push the gem"
  def release = sh "gem push pkg/#{app}-*.gem"
end
```

---

## Multi-File Layout

Split tasks across files by concern — each file reopens `class Tasks`:

```
myproject/
  .loki          ← entry point (may be empty or contain top-level task)
  build.loki     ← build-related tasks
  deploy.loki    ← deployment tasks
  test.loki      ← test tasks
```

```ruby
# build.loki
class Tasks
  desc "Compile the project"
  def build = sh "rake build"
end
```

```ruby
# test.loki
class Tasks
  depends_on :build
  desc "Run the test suite"
  def test = sh "bundle exec rake test"
end
```

```ruby
# deploy.loki
class Tasks
  depends_on :test
  desc "Deploy to production"
  def deploy = sh "cap production deploy"
end
```

```ruby
# .loki — can be empty, or can register subcommands, add top-level vars, etc.
```

Load order: `build.loki` → `deploy.loki` → `test.loki` → `.loki`.

!!! tip
    When `--auto-load` is used, `*.loki` files are sorted alphabetically, so `build.loki` loads before `test.loki`, which means `depends_on :build` in `test.loki` correctly references a task that already exists.

---

## Explicit Loading

You can explicitly load files from `.loki` using `require_relative`. This gives you control over load order, and lets you load plain Ruby files that are not `.loki` files:

```ruby
# .loki
require_relative "shared/helpers"
require_relative "ci.loki"

class Tasks
  include BuildHelpers   # defined in shared/helpers.rb

  desc "full-ci", "Complete CI run"
  def full_ci = sh "echo 'full CI complete'"
end
```

Explicitly required files are loaded before `.loki`'s own class body is evaluated. Files loaded via `require_relative` are **not** re-loaded by the alphabetical glob — Ruby's `require_relative` marks them as loaded in `$LOADED_FEATURES`.

!!! warning
    If you `require_relative "ci.loki"` from `.loki` and also run `asgard --auto-load`, Asgard's glob will also load `ci.loki`. To prevent double-loading, either: (a) put explicitly loaded files in a subdirectory outside the alphabetical sweep, or (b) rely solely on `--auto-load` without `require_relative`.

---

## Subcommands Across Files

Subcommand classes defined in separate `*.loki` files are available in `.loki` when `--auto-load` is used, because the `*.loki` files load first:

```
myproject/
  .loki                    ← registers subcommands
  db_subcommands.loki      ← defines DBCommands
  server_subcommands.loki  ← defines ServerCommands
```

```ruby
# db_subcommands.loki
class DBCommands < Tasks
  desc "Run migrations"
  def migrate = sh "rails db:migrate"
end

# server_subcommands.loki
class ServerCommands < Tasks
  desc "Start the server"
  def start = sh "rails server"
end

# .loki
class Tasks
  desc "db SUBCOMMAND",     "Manage the database"; subcommand "db",     DBCommands
  desc "server SUBCOMMAND", "Manage the server";   subcommand "server", ServerCommands
end
```

---

## Summary of Loading Rules

| File | When loaded | Purpose |
|---|---|---|
| `.loki` | After all `*.loki` | Project root marker; entry point |
| `*.loki` | When `--auto-load` is passed, alphabetically before `.loki` | Task definitions that reopen `class Tasks` |
| `require_relative` targets | At the point of the `require_relative` call | Shared helpers, explicit task files |
