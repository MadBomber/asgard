# Task Files

Asgard uses a convention-based file discovery system. A hidden `.loki` file marks the project root. Everything else — loading sibling files, shared task libraries, monorepo-wide tasks — is controlled explicitly from inside your `.loki` file using the `import` and `import_up` Kernel methods.

---

## The `.loki` Root Marker

When you run `asgard`, it searches for a `.loki` file starting in the current working directory and walking upward through parent directories until it finds one or reaches the filesystem root. The first `.loki` file found marks the project root and is the only file Asgard loads automatically.

```
myproject/
  .loki         ← found regardless of which subdirectory you're in
  src/
    app/
      # asgard still works from here
```

The `.loki` file can be completely empty — its presence alone marks the project root. It can also contain task definitions, `import` calls, or any valid Ruby.

---

## Loading Files with `import`

`import` is a Kernel method available everywhere in Ruby — at the top level of `.loki` files, inside class bodies, and inside task method bodies. It loads `.loki` files with `require`-like idempotency: a file is loaded at most once per process, no matter how many times `import` is called with the same path.

### Single file by absolute path

```ruby
import "/home/shared/gem_tasks.loki"
```

### Single file by relative path

Relative paths are resolved relative to the **caller's file location**, like `require_relative`:

```ruby
# .loki — relative to this file's directory
import "build.loki"
import "../shared/gem_tasks.loki"
import "tasks/ci.loki"
```

### All files in the same directory (glob)

```ruby
import "*.loki"      # all *.loki files in the same directory as the calling file
```

`*.loki` never matches `.loki` (the dotfile entry point) — Ruby's `Dir.glob` excludes dotfiles from `*` patterns by default.

### All files recursively (recursive glob)

```ruby
import "**/*.loki"   # every .loki file in this directory and all subdirectories
```

### Specific named files

```ruby
import "gem_tasks.loki"
import "ci_tasks.loki"
```

### Combining patterns

```ruby
# .loki
import "*.loki"           # load all siblings
import "../shared/*.loki" # load a parent-level shared library
```

### Typical `.loki` entry point

```ruby
# .loki
import "*.loki"    # load all sibling task files

class Tasks
  # any top-level task definitions or overrides
end
```

### Return value

`import` returns `true` if at least one file was newly loaded, `false` if all files were already loaded or no glob pattern matched any file. If a specific (non-glob) file does not exist, `import` raises `LoadError`.

```ruby
import("gem_tasks.loki") ? "loaded now" : "already loaded"
```

---

## Finding Files with `loki_up`

`loki_up(name = ".loki")` searches `Dir.pwd` and each ancestor directory for a file with the given name, returning its absolute path or `nil`. It does **not** load the file — it only finds it.

Despite the name, `loki_up` is not limited to `.loki` files — it will locate any file by name. This makes it useful for finding shared config files, `.env` files, or any other resource that lives somewhere up the directory tree:

```ruby
loki_up                    # finds .loki (the project root marker)
loki_up("gem_tasks.loki")  # finds gem_tasks.loki in CWD or any ancestor
loki_up(".env")            # finds the nearest .env file up the tree
loki_up("VERSION")         # finds a VERSION file in CWD or any ancestor
```

Use `loki_up` when you need the path for other purposes, or to check whether a file exists before deciding to load it:

```ruby
if (path = loki_up("gem_tasks.loki"))
  import path
end

# Pass the located .env to dotenv — works from any subdirectory
dotenv loki_up(".env") || ".env"
```

`loki_up` accepts exact filenames only. Glob patterns are not expanded by `loki_up` — use `import_up` for glob-aware ancestor search.

---

## Loading Files Found up the Tree with `import_up`

`import_up(name = ".loki")` combines `loki_up` and `import` into a single call. It finds the file (or files) up the ancestor chain and loads them.

### Exact filename

```ruby
import_up "gem_tasks.loki"
```

Walks up from `Dir.pwd` until it finds `gem_tasks.loki`, then loads it. Returns `false` if not found anywhere.

### Glob pattern

```ruby
import_up "*.loki"
```

Walks up from `Dir.pwd` and stops at the **first ancestor directory** that contains any `*.loki` files, loading all of them. It does not aggregate matches from multiple levels — it loads only the nearest match, then stops.

```
~/sandbox/
  shared/
    gem_tasks.loki     ← loaded by import_up("*.loki") from ~/sandbox/myproject/sub/
    ci_tasks.loki      ← also loaded — same directory as the first match
  myproject/
    .loki
    sub/
      # Dir.pwd here; import_up("*.loki") finds ~/sandbox/shared/
```

### Return value

Returns `true` if any file was newly loaded, `false` if the file was not found or was already loaded.

### Conditional load

Since `import_up` returns `false` when a file is not found (rather than raising), it composes naturally with `||`:

```ruby
import_up("project_tasks.loki") || import_up("gem_tasks.loki")
```

---

## Idempotency

Both `import` and `import_up` track loaded files in Ruby's `$LOADED_FEATURES`. A second call with the same path is a no-op and returns `false`. This means:

- You can call `import "*.loki"` from both `.loki` and a shared task file without double-loading.
- `import_up("gem_tasks.loki")` from two different projects in the same process each load their nearest match once.
- Swapping `require` for `import` in a `.loki` file gives the same once-per-process guarantee.

---

## Verbose and Debug Feedback

`import` and `import_up` emit diagnostic messages to stderr when the `verbose?` or `debug?` flags are active (set via `--verbose` or `--debug` on the CLI, or by setting `$VERBOSE`/`$DEBUG` directly):

| Flag | `import` output | `import_up` output |
|---|---|---|
| `--verbose` | Prints each file path as it is loaded | Prints `name → /full/path` when found |
| `--debug` | Same as verbose, plus prints a skip message for already-loaded files | Same as verbose, plus prints `name not found` when the search comes up empty |

```
$ asgard --verbose build
import: /home/user/myproject/build.loki
import: /home/user/myproject/test.loki
```

---

## Loading Patterns

### Single-file project

All tasks in `.loki`, nothing else:

```ruby
# .loki
class Tasks
  @@app ||= "myapp".freeze

  desc "Compile the project"
  def build = sh "rake build"

  desc "Run the test suite"
  def test = sh "rake test"

  desc "Build and push the gem"
  def release = sh "gem push pkg/#{@@app}-*.gem"
end
```

### Multi-file project

Split tasks across files by concern. Load them all from `.loki` with a glob:

```
myproject/
  .loki          ← entry point; imports siblings
  build.loki     ← build tasks
  deploy.loki    ← deploy tasks
  test.loki      ← test tasks
```

```ruby
# .loki
import "*.loki"
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

Files loaded via glob are sorted alphabetically by `Dir.glob`, so `build.loki` loads before `test.loki`. Tasks defined in earlier files are available to later files via `depends_on`.

### Controlled load order

When alphabetical order does not match your dependency order, import explicitly:

```ruby
# .loki
import "infra.loki"    # must be first
import "build.loki"    # depends on infra
import "deploy.loki"   # depends on build
```

### Shared task library in a monorepo

Place shared tasks in a parent directory and load them from any sub-project:

```
~/sandbox/
  gem_tasks.loki        ← shared: build, install, release tasks for any gem
  myproject/
    .loki               ← loads gem_tasks.loki via import_up
  other_project/
    .loki               ← also loads gem_tasks.loki via import_up
```

```ruby
# myproject/.loki
import_up "gem_tasks.loki"   # finds ~/sandbox/gem_tasks.loki

class Tasks
  # project-specific overrides here
end
```

### Conditional shared library

```ruby
# .loki
import_up("ci_tasks.loki") || import_up("gem_tasks.loki")
```

Loads `ci_tasks.loki` if found up the tree, otherwise falls back to `gem_tasks.loki`.

### Subcommand classes across files

Define subcommand classes in separate files and register them in `.loki`:

```
myproject/
  .loki
  db.loki
  server.loki
```

```ruby
# db.loki
class DBCommands < Tasks
  desc "Run migrations"
  def migrate = sh "rails db:migrate"
end
```

```ruby
# server.loki
class ServerCommands < Tasks
  desc "Start the server"
  def start = sh "rails server"
end
```

```ruby
# .loki
import "*.loki"   # db.loki and server.loki load first

class Tasks
  desc "db SUBCOMMAND",     "Manage the database"; subcommand "db",     DBCommands
  desc "server SUBCOMMAND", "Manage the server";   subcommand "server", ServerCommands
end
```

Subcommand classes are available in `.loki` because siblings loaded via `import "*.loki"` execute before `.loki`'s own class body.

---

## Task Name Overloading

Because all `*.loki` files reopen the same `class Tasks`, two files can define a method with the same name. Ruby's class reopening semantics apply: the last definition loaded wins, silently replacing the earlier one.

Three things are overwritten when a task name is reused:

| What | Effect |
|---|---|
| `def method_name` | The Ruby method body — the earlier implementation is gone |
| `desc` metadata | Thor registers the new usage/description string, discarding the old one |
| `depends_on` stages | `method_added` captures the pending deps for the new definition; the earlier dep chain is replaced |

**Accidental overloading** is a silent bug. Keep task names unique across files.

!!! warning
    There is no runtime error when a task is overloaded. If a task is not behaving as expected, check whether another `.loki` file defines the same method name and loads after it.

**Intentional overloading** lets you extend a task defined in an earlier file using `alias_method`:

```ruby
# build.loki  (loaded first)
class Tasks
  desc "Compile the project"
  def build = sh "rake build"
end

# postbuild.loki  (loaded after build.loki, alphabetically)
class Tasks
  no_commands { alias_method :_build_original, :build }

  desc "Compile the project and copy assets"
  def build
    _build_original
    sh "cp -r dist/ public/"
  end
end
```

!!! warning "Prefer `depends_on` over intentional overloading"
    Using `alias_method` to bolt post-task behaviour onto an existing task is fragile and load-order dependent. The idiomatic alternative is `depends_on`:

    ```ruby
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

---

## Summary of Loading Rules

| Method | Finds? | Loads? | Glob? | Ancestor search? |
|---|---|---|---|---|
| `loki_up(name)` | Yes | No | No | Yes |
| `import(path)` | No | Yes | Yes | No |
| `import_up(name)` | Yes | Yes | Yes | Yes |
| Asgard's `run!` | Yes | `.loki` only | No | Yes |
