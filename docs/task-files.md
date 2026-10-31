# Task Files

Every asgard project is a directory with a file named `.loki` in it. That file marks the project root and is the only file asgard loads on its own. Everything else, from a second task file next to it to a library of tasks shared by a whole workspace, is something your `.loki` asks for with `import`.

This page starts with the marker itself, then covers the three ways to bring in more files (`import`, `loki_up`, `import_up`), the layouts that fall out of them, and what happens when two files define the same task.

The smallest possible project:

```bash
mkdir myproject && cd myproject
touch .loki
asgard help        # works; lists only asgard's built-in commands
```

---

## The `.loki` Root Marker

When you run `asgard`, it looks for a file named `.loki` in the current directory, then in its parent, and so on up to the filesystem root. The first one it finds is the project root. It is loaded, and nothing else is.

```
myproject/
  .loki            found from anywhere below it
  src/
    app/           asgard works from here too
```

Three details:

- **It may be empty.** Its presence is what marks the root. A `.loki` with no content still lets `asgard help`, `asgard jobs` and the rest run.
- **A directory named `.loki` does not count.** Only a file does.
- **The nearest one wins.** If there is a `.loki` in your home directory and another in a project below it, running asgard inside the project uses the project's. The one above is never reached, and `asgard --doctor` lists it as a shadowed marker (see [Help & Diagnostics](diagnostics.md#the-doctor-report)).

Without a `.loki` anywhere above the current directory:

```
asgard: no .loki file found in /Users/you/Downloads
```

The three listing commands that cover every project on the machine, `asgard schedule list`, `asgard watcher list` and `asgard jobs list`, are the exception. They run anywhere.

### Asgard Does Not Change Directory

Finding `.loki` upward does not move you there. A task runs in the directory you ran `asgard` from, so a relative path in a task is relative to that directory. When a task needs the project root, ask for it:

```ruby
class Tasks
  desc "Show where things are"
  def where
    puts "running in:   #{Dir.pwd}"
    puts "project root: #{loki_up.dirname}"
  end
end
```

```bash
cd src/app && asgard where
# running in:   /Users/you/myproject/src/app
# project root: /Users/you/myproject
```

Tasks started by the [watcher](watch.md) or a [schedule](schedule.md) always run from the project root.

<figure markdown>
--8<-- "docs/assets/images/loki-layout.svg"
<figcaption>The root <code>.loki</code> is found from any subdirectory. It imports its siblings, and may import a shared file from higher up. Every file reopens the same <code>Tasks</code> class.</figcaption>
</figure>

---

## Loading Files with `import`

`import` loads another task file. It works at the top of a `.loki` file, inside a `class Tasks` body, and inside a task method. The usual place is the first line of `.loki`:

```ruby
# .loki
import "*.loki"

class Tasks
  # tasks that belong at the top level, if any
end
```

### Every Form

```ruby
import "build.loki"                   # one file, relative to this file's directory
import "tasks/ci.loki"                # a file in a subdirectory
import "../shared/gem_tasks.loki"     # a file in a parent directory
import "/home/shared/gem_tasks.loki"  # an absolute path
import "*.loki"                       # every .loki file beside this one
import "**/*.loki"                    # every .loki file in this directory and below
import Pathname.new("tasks.loki")     # a Pathname works too
```

A relative path is resolved from the directory of the file that contains the `import`, not from where you ran asgard. That is what makes a `.loki` work from any subdirectory.

### The Rules

- **The path must end in `.loki`.** Anything else raises `ArgumentError: import: path must end with .loki`. A plain Ruby file is loaded with `require_relative` instead (see [Helper Methods](helpers.md#sharing-helpers-across-files)).
- **A glob never matches `.loki` itself.** `*.loki` picks up `build.loki` and `deploy.loki`, never the dotfile, so a `.loki` that imports `*.loki` does not load itself again.
- **Glob matches load in alphabetical order.** `build.loki`, `deploy.loki`, `test.loki`.
- **A file loads once.** Importing the same file twice, from two different files, or through both a glob and a name, loads it the first time and skips it after that. You never get a task defined twice because two files both asked for the same helper file.
- **A named file that does not exist stops asgard** with a one-line error:

    ```
    asgard: /Users/you/myproject/.loki:1: cannot load such file -- /Users/you/myproject/missing.loki (LoadError)
    ```

    A glob that matches nothing is not an error; it just loads nothing.

### Return Value

`import` returns `true` when it loaded at least one new file and `false` when every match was already loaded or the glob matched nothing. You rarely need this, but it makes a conditional read naturally. Write the name as a glob, so a missing file matches nothing instead of raising `LoadError`:

```ruby
import("local_overrides*.loki") || puts("no local overrides")
```

---

## Finding Files with `loki_up`

`loki_up(name = ".loki")` searches the current directory and each parent for a file with that name and returns its path as a `Pathname`, or `nil`. It only finds; it never loads.

Despite the name it is not limited to `.loki` files. Any file that lives somewhere up the tree is fair game:

```ruby
loki_up                     # the .loki marker itself
loki_up("gem_tasks.loki")   # a shared task file in this directory or above
loki_up(".env")             # the nearest .env
loki_up("VERSION")          # a VERSION file
```

Two common uses:

```ruby
class Tasks
  # Load the project's .env from any subdirectory (see Environment Variables)
  dotenv loki_up(".env") || ".env"

  # The project root, for paths that must not depend on where asgard ran
  helper(:root) { loki_up.dirname }

  desc "Build the docs"
  def docs = sh "mkdocs build -f #{root.join('mkdocs.yml')}"
end
```

`loki_up` takes an exact filename. For a pattern, use `import_up`.

---

## Loading Files Found Up the Tree with `import_up`

`import_up(name = ".loki")` is `loki_up` and `import` in one call: find the file in the current directory or an ancestor, then load it.

```ruby
import_up "gem_tasks.loki"
```

Walks upward until it finds `gem_tasks.loki` and loads it. It returns `false` without raising when nothing is found, which is what makes a shared file optional:

```ruby
import_up("ci_tasks.loki") || import_up("gem_tasks.loki")   # the first one found wins
import_up "team_tasks.loki"                                  # fine if it is not there
```

With a glob, `import_up` stops at the **first ancestor directory that has any match** and loads everything that matches there. It does not keep walking and collect matches from several levels:

```
~/sandbox/
  gem_tasks.loki      loaded by import_up("*.loki") from myproject/sub/
  ci_tasks.loki       also loaded: same directory as the first match
  myproject/
    .loki
    sub/              asgard runs here
```

!!! note
    `import_up` searches from the directory you ran asgard in, not from the file that calls it. Run from `myproject/sub/`, a glob search looks in `sub/`, then `myproject/`, then `~/sandbox/`. With an exact filename the difference rarely matters, because the file is above the project either way.

---

## Load Order

Files load in the order your `.loki` asks for them, and a `.loki` that starts with `import "*.loki"` loads every sibling before its own `class Tasks` body runs. For most things order does not matter:

- A `depends_on :build` may name a task defined in a file that loads later. Dependency names are checked once every file has loaded, not when the line is read.
- `desc`, options and `depends_on` attach to the `def` that follows them in the same file.

Order matters for the few things that are "first wins" or "last wins":

| Declaration | Rule |
|---|---|
| `@@name ||= value` | First file to set it wins; later files see the value |
| `def name` | Last definition wins, silently (see [Task Name Overloading](#task-name-overloading)) |
| `default_task :name` | Last call wins, with a warning on stderr naming both locations |
| `header` / `footer` | Every call is kept; see [Help & Diagnostics](diagnostics.md#header-and-footer) for the order they print in |
| `shell` / `default_shell` | Last call wins |

When alphabetical order is not the order you want, name the files:

```ruby
# .loki
import "infra.loki"     # first
import "build.loki"     # then this
import "deploy.loki"    # then this
```

---

## Tracing Imports

To see which files load, turn on Ruby's warnings for the run:

```bash
RUBYOPT=-w asgard build
# import: /Users/you/myproject/build.loki
# import: /Users/you/myproject/deploy.loki
# import: /Users/you/myproject/test.loki
```

`asgard build --verbose` prints the same lines, but only for an `import` that runs inside a task body, because the flag takes effect after the task files have loaded. Add `--debug` to also see a file that was skipped because it was already loaded, and an `import_up` that found nothing:

```bash
asgard build --verbose --debug
# import: skip /Users/you/myproject/extra.loki (already loaded)
# import_up: team_tasks.loki not found
```

`asgard --doctor` shows the whole import chain without running anything; see [Help & Diagnostics](diagnostics.md#the-doctor-report).

---

## Loading Patterns

### A Single File

Everything in `.loki`, nothing to import:

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

### One File per Concern

Split tasks by what they do and load them all with a glob:

```
myproject/
  .loki          imports the rest
  build.loki     compile, package
  deploy.loki    deploy to staging and production
  test.loki      tests and lint
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

```bash
asgard deploy    # build → test → deploy
```

### A Shared Library for Many Projects

Put tasks that every project needs in a parent directory and let each project pull them in with `import_up`:

```
~/sandbox/
  gem_tasks.loki       build, install, release for any gem
  myproject/
    .loki
  other_project/
    .loki
```

```ruby
# myproject/.loki
import_up "gem_tasks.loki"

class Tasks
  @@project ||= "myproject".freeze   # gem_tasks.loki reads this
end
```

!!! tip
    A shared file should not hardcode the project's name. Read it from a class variable each project sets, as above, and set it with `||=` so the project's value is the one that wins whichever file loads first. See [Variables](variables.md).

### Conditional Imports

A `.loki` is Ruby, so an `import` can sit inside an `if`:

```ruby
# .loki
import "quality.loki"
import "quality_rails.loki" if ENV["RAILS_ROOT"]
import "local.loki"         if File.exist?(File.join(__dir__, "local.loki"))
```

The second line adds Rails-only checks when the project says it is a Rails app. A task in another file that wants "every `*_check` task, whichever files loaded" uses the block form of `depends_on` to discover them; see [Dependencies](dependencies.md#dynamic-dependencies).

### Subcommand Classes in Their Own Files

Define each subcommand class in its own file and register them in `.loki`. Because the siblings are imported at the top of `.loki`, the classes exist by the time `.loki`'s own `class Tasks` body runs:

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
import "*.loki"

class Tasks
  desc "db SUBCOMMAND",     "Manage the database"; subcommand "db",     DBCommands
  desc "server SUBCOMMAND", "Manage the server";   subcommand "server", ServerCommands
end
```

See [Subcommands](subcommands.md).

---

## Task Name Overloading

Every file reopens the same `Tasks` class, so two files can define a method with the same name. Ruby keeps the last one it sees and says nothing. The earlier task is gone: its body, its `desc`, and its `depends_on`.

```ruby
# build.loki (loads first)
class Tasks
  desc "Compile the project"
  def build = sh "rake build"
end

# postbuild.loki (loads second)
class Tasks
  desc "Copy assets"
  def build = sh "cp -r dist/ public/"     # this is now the only `build`
end
```

`asgard build` copies assets and never compiles. There is no error, so when a task does not do what its file says, check for a second definition. `asgard --doctor` reports every one:

```
Tasks by file:

  build.loki
    build  build.loki:3   OVERRIDDEN by postbuild.loki:3 — never callable

  postbuild.loki
    build  postbuild.loki:3   active — redefines build.loki:3
```

If you do mean to extend a task from another file, give each step its own task and chain them with `depends_on`:

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

The `alias_method` trick (keep the old body under a new name, then redefine) also works, but it depends on which file loads first and hides the first task from help. Prefer the version above.

---

## A Real Example: Asgard's Own Task Files

The asgard repository is run by asgard. Its root `.loki` is a multi-file project in exactly the shape this page describes:

```ruby
# .loki
import "quality.loki"
import "quality_rails.loki" if ENV["RAILS_ROOT"]
import "gem_tasks.loki"
import "git.loki"
import "doc_tasks.loki"
import "xyzzy.loki"   # an example for the --doctor flag

class Tasks
  @@project      ||= "asgard".freeze
  @@project_desc ||= "CLI-task runner"

  watch :test_check, paths: %w[lib test], only: /\.rb\z/

  helper(:project_version) do
    @@project_version ||= loki_up.dirname.join("lib/#{@@project}/version.rb").read.match(/VERSION\s*=\s*"([^"]+)"/)[1].freeze
  end

  default_task :quality

  header <<~HEAD
    Project:  #{@@project} (v#{project_version}) - #{@@project_desc}
    Root Dir: #{loki_up.parent}
    Default task: #{default_task}
  HEAD
end
```

| File | What it holds |
|---|---|
| `quality.loki` | One `*_check` task per quality tool (tests, RuboCop, Flog, Flay, Reek, typos, ...) and a `quality` task whose block-form `depends_on` runs every `*_check` in parallel and prints a summary from their results |
| `quality_rails.loki` | Rails-only checks (Brakeman and friends), loaded only when `RAILS_ROOT` is set; `quality` picks them up with nothing else to change |
| `gem_tasks.loki` | `console`, plus `build` (depends on `quality`), `install` (depends on `build`) and `release` (depends on `build`, after checking the branch is `main`) |
| `git.loki` | `push`, `pull` and `fetch` |
| `doc_tasks.loki` | The `doc` subcommand group for an MkDocs or Bridgetown site: `doc install`, `doc build`, `doc serve` (a background job) and `doc open`, each depending on the one before |
| `xyzzy.loki` | A `xyzzy` task that `.loki` deliberately redefines, so `asgard --doctor` has an override to report |

Clone the repository and run `asgard help`, `asgard tree` and `asgard --doctor` from its root to see each of these in action. The [Examples](examples.md) page walks through the rest of `examples/`.

---

## Summary of Loading Rules

| Call | Finds? | Loads? | Glob? | Searches ancestors? | Not found |
|---|---|---|---|---|---|
| `loki_up(name)` | Yes, returns a `Pathname` | No | No | Yes | Returns `nil` |
| `import(path)` | No | Yes | Yes | No | Named file: error; glob: nothing loads |
| `import_up(name)` | Yes | Yes | Yes, first matching ancestor | Yes | Returns `false` |
| Starting `asgard` | `.loki` only | `.loki` only | No | Yes | `asgard: no .loki file found in ...` |
