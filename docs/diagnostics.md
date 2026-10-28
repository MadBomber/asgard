# Help & Diagnostics

This page is about finding out what asgard knows and why something did not work: the help pages, the command tree, the text you can add above and below them, the `--doctor` report, and every error asgard prints at startup, with its exit status.

Start with the two commands you will use most:

```bash
asgard help          # every task, with its description
asgard --doctor      # which files loaded, which tasks each defines, what is wrong
```

---

## `asgard help`

`asgard help` (or `asgard` with no arguments, when no `default_task` is set) lists every task that has a `desc`, the built-in groups, and the options every task accepts:

```
asgard v0.6.0 The Mighty Thor and Loki working for you

Commands:
  asgard build                # Compile the project
  asgard deploy ENV           # Deploy to ENV
  asgard help [COMMAND]       # Describe available commands or one specific command
  asgard jobs SUBCOMMAND      # List, stop and restart the background jobs started with `sh ..., background: true`
  asgard schedule SUBCOMMAND  # Manage schedules declared with `schedule :task, ...` (launchd on macOS, systemd on Linux)
  asgard test                 # Run the test suite
  asgard tree                 # Print a tree of all available commands
  asgard watcher SUBCOMMAND   # Run and manage the file watcher declared with `watch :task, paths: ...`

Options:
  [--debug]    # Enable debug mode ($DEBUG = true)
               # Default: false
  [--verbose]  # Enable verbose output ($VERBOSE = true)
               # Default: false
  [--version]  # Show asgard version and exit
               # Default: false
  [--doctor]   # Diagnose .loki resolution, imports, and task definitions for the CWD, then exit
               # Default: false

Documentation ... https://madbomber.github.io/asgard
Github Repo ..... https://github.com/MadBomber/asgard
```

The first line and the last two are asgard's own header and footer. Yours go between them; see [`header` and `footer`](#header-and-footer). A task defined without a `desc`, or with `desc "...", hide: true`, is left out of the list but still runs.

`asgard help TASK` shows one task: its usage line with positional parameters, its own options followed by the shared ones, and its `long_desc` when it has one:

```bash
asgard help deploy
```

```
Usage:
  asgard deploy ENV

Options:
  -b, [--branch=BRANCH]          # Git branch to deploy
                                 # Default: main
  -n, [--dry-run], [--no-dry-run], [--skip-dry-run]  # Print commands without running
  [--debug]                      # Enable debug mode ($DEBUG = true)
  ...

Deploy ENV
```

Per-task help does not show the header or footer. For a subcommand group, `asgard help db`, `asgard db help` and `asgard db help migrate` all work; see [Subcommands](subcommands.md#help-for-a-group).

!!! tip
    Put asgard's options after the task name: `asgard build --verbose`. Written before it, `asgard --verbose build` is read as `asgard help build`. The two flags that answer and exit, `--version` and `--doctor`, are the exception and go first.

---

## `asgard tree`

`asgard tree` prints the commands as a tree: the top-level tasks first, with each subcommand group as one leaf, then one section per group listing its own tasks. Header and footer are shown, as on `help`:

```bash
asgard tree
```

```
asgard v0.6.0 The Mighty Thor and Loki working for you

tasks
  ├─ _jobs (List, stop and restart the background jobs started with `sh ..., background: true`)
  ├─ _schedule (Manage schedules declared with `schedule :task, ...` (launchd on macOS, systemd on Linux))
  ├─ _watcher (Run and manage the file watcher declared with `watch :task, paths: ...`)
  ├─ build (Compile the project)
  ├─ db (Manage the database)
  └─ deploy (Deploy to ENV)
  schedule
    ├─ install (Install this project's schedule declarations (removes undeclared ones))
    ├─ list (Show this project's installed entries, their state, and last exit status)
    ...
  watcher
    ...
  jobs
    ...
  db
    ├─ migrate (Run pending migrations)
    └─ seed (Load seed data)
```

The built-in groups appear as leaves under their reserved names (`_jobs`, `_schedule`, `_watcher`) and as sections under the names you type (`jobs`, `schedule`, `watcher`). A group of your own gets a section under the name it was registered with, so `subcommand "db", DBCommands` shows as `db`.

---

## `header` and `footer`

`header "text"` and `footer "text"` in the class body add lines above the command list and below the options block on `asgard help` and `asgard tree`:

```ruby
class Tasks
  header "my-project: build and release tasks"
  footer "See https://example.com/docs for details"
end
```

Both may be called more than once, and from more than one file. Every call is kept. The difference is the order:

- **`header` appends.** Each call goes below the previous ones, so the first file to call it (usually `.loki`) stays at the top.
- **`footer` prepends.** Each call goes above the previous ones, so text from a file that loads later sits closer to the commands.

```ruby
# .loki
class Tasks
  header "my-project"
  footer "Maintainer: you@example.com"
end
import "deploy.loki"
```

```ruby
# deploy.loki
class Tasks
  header "  deploy targets: staging, production"
  footer "See runbook at wiki/deploy"
end
```

```
asgard v0.6.0 The Mighty Thor and Loki working for you

my-project

  deploy targets: staging, production

Commands:
  asgard deploy  # Deploy
  ...

Options:
  ...

See runbook at wiki/deploy

Maintainer: you@example.com


Documentation ... https://madbomber.github.io/asgard
Github Repo ..... https://github.com/MadBomber/asgard
```

Each call is separated from the next by a blank line. A multi-line heredoc counts as one call, so lines that belong together go in one heredoc.

A header that needs a computed value uses `helper`, which defines a method usable in the class body. This is how asgard's own `.loki` prints its version and root:

```ruby
class Tasks
  @@project ||= "asgard".freeze

  helper(:project_version) do
    @@project_version ||= loki_up.dirname.join("lib/#{@@project}/version.rb").read.match(/VERSION\s*=\s*"([^"]+)"/)[1].freeze
  end

  header <<~HEAD
    Project:  #{@@project} (v#{project_version})
    Root Dir: #{loki_up.parent}
    Default task: #{default_task}
  HEAD
end
```

See [Helper Methods](helpers.md#the-helper-dsl-method).

---

## The Doctor Report

`asgard --doctor` loads the task files the way a normal run would, but instead of running a task it reports what it found. Reach for it when:

- a task you defined does not show up, or runs something other than what its file says
- asgard reports a dependency error and you want to see every definition involved
- an `import` seems to load nothing
- you suspect a `.loki` higher up the tree is being used instead of the one you expect

It also works when a normal run cannot start at all, because a file is broken or a dependency graph has a cycle. That is the point: it tells you where, instead of stopping.

```bash
asgard --doctor
```

```
asgard doctor -- /Users/you/myproject
============================================================
  [INFO] using .loki marker: /Users/you/myproject/.loki
  [WARN] shadowed marker (never reached): /Users/you/.loki
  [INFO] import "quality.loki" -> /Users/you/myproject/quality.loki
  [INFO] import "gem_tasks.loki" -> /Users/you/myproject/gem_tasks.loki
  [INFO] import "local.loki" -- nothing new (not found or already loaded)

Tasks by file:

  .loki
    deploy  .loki:12
    where   .loki:18   hidden (no desc; not shown by help)

  quality.loki
    test_check     quality.loki:11
    quality        quality.loki:30
    rubocop_check  quality.loki:39

  gem_tasks.loki
    build    gem_tasks.loki:16
    release  gem_tasks.loki:31
============================================================
No problems found (1 warning(s)).
```

### Reading the Report

| Line | Meaning |
|---|---|
| `[INFO] using .loki marker: ...` | The `.loki` a run from this directory uses |
| `[WARN] shadowed marker (never reached): ...` | Another `.loki` further up the tree. Harmless, but if you expected that one to be used, this is why it is not |
| `[INFO] import "x" -> /path/a.loki, /path/b.loki` | What each `import` and `import_up` loaded, in order, including imports made by imported files |
| `[INFO] import "x" -- nothing new (not found or already loaded)` | A glob that matched nothing, or a file that an earlier import already loaded |
| `[FAIL] load failed: NoMethodError: ...` | A task file raised while loading. The normal run would stop with the same message |
| `[FAIL] Tasks dependency graph: ...` | A cycle, an undefined dependency, or another graph problem, in the named class |

**Tasks by file** lists every loaded file and, under each, the tasks it defines in line order, as `name file:line`, a form most editors can jump to. A file that defines no tasks says `(no tasks defined — imports only)`. When the project has [subcommand](subcommands.md) classes, the listing repeats once per class under headings such as `Tasks by file (DocCommands):` and `Tasks by file (Tasks):`. Each section still lists every loaded file, so a file whose tasks all belong to another class shows the imports-only note in this one. Two notes can follow a task:

- `hidden (no desc; not shown by help)`: a public method without a `desc`. It runs from the command line and as a dependency, but help leaves it out. If it was meant as a helper, make it `private`, put it in `no_commands`, or use `helper`. See [Defining Tasks](tasks.md#hidden-tasks).
- `OVERRIDDEN by file:line — never callable` and `active — redefines file:line`: the same task name defined twice. Only the last definition exists; the earlier one is dead. Each overridden task counts as one problem in the summary.

The summary line is `No problems found.`, `No problems found (N warning(s)).` or `N problem(s), M warning(s).`

### A Deliberate Override

The asgard repository ships an example. `xyzzy.loki` defines a `xyzzy` task, and the root `.loki`, which imports it, defines `xyzzy` again. Run `asgard --doctor` from a clone:

```
asgard doctor -- /Users/you/asgard
============================================================
  [INFO] using .loki marker: /Users/you/asgard/.loki
  [INFO] import "quality.loki" -> /Users/you/asgard/quality.loki
  [INFO] import "gem_tasks.loki" -> /Users/you/asgard/gem_tasks.loki
  [INFO] import "git.loki" -> /Users/you/asgard/git.loki
  [INFO] import "doc_tasks.loki" -> /Users/you/asgard/doc_tasks.loki
  [INFO] import "xyzzy.loki" -> /Users/you/asgard/xyzzy.loki

Tasks by file (DocCommands):

  .loki
    (no tasks defined — imports only)

  quality.loki
    (no tasks defined — imports only)

  gem_tasks.loki
    (no tasks defined — imports only)

  git.loki
    (no tasks defined — imports only)

  doc_tasks.loki
    install  doc_tasks.loki:43
    build    doc_tasks.loki:52
    serve    doc_tasks.loki:63
    open     doc_tasks.loki:71
    help     doc_tasks.loki:138

  xyzzy.loki
    (no tasks defined — imports only)

Tasks by file (Tasks):

  .loki
    xyzzy  .loki:26   active — redefines xyzzy.loki:6

  quality.loki
    test_check           quality.loki:11
    test_verbose         quality.loki:14
    parallel_test        quality.loki:21
    quality              quality.loki:37
    ...

  gem_tasks.loki
    console  gem_tasks.loki:6
    build    gem_tasks.loki:16
    install  gem_tasks.loki:24
    release  gem_tasks.loki:31

  git.loki
    push   git.loki:6
    pull   git.loki:9
    fetch  git.loki:12

  doc_tasks.loki
    doc  doc_tasks.loki:138

  xyzzy.loki
    xyzzy  xyzzy.loki:6   OVERRIDDEN by .loki:26 — never callable
============================================================
1 problem(s), 0 warning(s).
```

`doc_tasks.loki` defines the `DocCommands` group behind `asgard doc`, so the report has one section for that class and one for `Tasks`. The `xyzzy` override shows up in the `Tasks` section, and a `.loki` further up your tree would add a shadowed-marker warning to the count.

### When the Files Do Not Load

A broken file still gets a report. The load failure is the finding, and there is no task listing because nothing finished loading:

```
asgard doctor -- /Users/you/myproject
============================================================
  [INFO] using .loki marker: /Users/you/myproject/.loki
  [FAIL] load failed: NoMethodError: undefined method 'dependz_on' for class Tasks
============================================================
1 problem(s), 0 warning(s).
```

A dependency problem, on the other hand, loads fine, so the listing is there to help you find the definitions:

```
  [FAIL] Tasks dependency graph: topological sort failed: [:a, :b]

Tasks by file:

  .loki
    a  .loki:3
    b  .loki:5
```

---

## Load Errors

A task file that raises while loading stops asgard with one line: where, what, and the error class. The location is the nearest line inside a `.loki` file.

A typo in a DSL word:

```
asgard: /Users/you/myproject/.loki:2: undefined method 'dependz_on' for class Tasks (NoMethodError)
```

A syntax error (the location comes from Ruby's own message):

```
asgard: /Users/you/myproject/.loki:4: syntax error found (SyntaxError)
```

A `shell` whose executable does not exist:

```
asgard: /Users/you/myproject/.loki:2: shell :bash: /nope/bash is not an executable file (ArgumentError)
```

An `import` of a file that is not there:

```
asgard: /Users/you/myproject/.loki:1: cannot load such file -- /Users/you/myproject/missing.loki (LoadError)
```

When one line is not enough, set `ASGARD_TRACE` to get the whole backtrace, including Ruby's "Did you mean?" suggestion:

```bash
ASGARD_TRACE=1 asgard help
```

```
/Users/you/myproject/.loki:2:in '<class:Tasks>': undefined method 'dependz_on' for class Tasks (NoMethodError)
Did you mean?  depends_on
	from /Users/you/myproject/.loki:1:in '<top (required)>'
	...
```

---

## Startup Validation Errors

After every file has loaded, and before any task runs, asgard checks the dependency graph and the declarations. Each problem is one line and exit status 1.

| Problem | Message |
|---|---|
| Two tasks depend on each other, directly or through others | `asgard: circular dependency — topological sort failed: [:a, :b]` |
| A `depends_on` names a task that does not exist | `asgard: undefined task(s) in depends_on: ghost` |
| A `depends_on` with no `def` after it (at the end of a class body) | `asgard: depends_on(a) declared without a following task definition` |
| A dependency takes a required argument | `asgard: task 'b' has 1 required argument(s) and cannot be used as a dependency` |
| A block-form `depends_on` returned the wrong shape | `asgard: depends_on proc/block for 'quality' returned invalid stage 123 (Integer); expected a Symbol, String, or Array of them` |
| A block-form `depends_on` raised | `asgard: depends_on proc for 'quality' raised RuntimeError: boom` |
| A task or helper uses a name asgard's command machinery needs (`shell`, `options`, `invoke`, `run`, `args`, ...) | `asgard: 'args' at /Users/you/myproject/.loki:3 is a name Thor reserves and cannot be a task or helper; rename it` |
| Two different `schedule` declarations under one name | `asgard: /Users/you/myproject/.loki:4: schedule: "a" is already declared; give one a distinct as: name (ArgumentError)` |
| Two different `watch` declarations under one name | `asgard: /Users/you/myproject/.loki:4: watch: "a" is already declared; give one a distinct as: name (ArgumentError)` |

The last three are raised while the file loads, so they carry a file and line like any [load error](#load-errors). `asgard --doctor` reports the dependency ones under `Tasks dependency graph`, with the task listing beneath, and the others as `load failed`.

---

## Runtime Errors

Once a task is running, three kinds of error end the run:

**An error you raise.** `raise Asgard::Error, "message"` inside a task prints `asgard: message` and exits 1, with no backtrace. It is the right way for a task, or a dependency, to refuse to go on:

```ruby
class Tasks
  desc "Deploy to production"
  def deploy
    raise Asgard::Error, "working tree is not clean" unless `git status --porcelain`.empty?
    sh "cap production deploy"
  end
end
```

```
asgard: working tree is not clean
```

Any other exception prints Ruby's usual message and backtrace.

**A failing command.** When a `sh` or `shebang` script exits non-zero, asgard exits with that status at once. Nothing after the call runs. See [Shell Commands](shell.md#exit-on-failure).

**A usage error.** A missing argument, an unknown option, an unknown command or an ambiguous abbreviation prints a one-line message and exits 1:

```
Could not find command "nope".
Ambiguous command test matches [test_check, test_verbose]
asgard: unknown command '_version'
```

The last one is asgard refusing a name that starts with `_`, which is reserved for its built-ins.

---

## Exit Status

| Status | When |
|---|---|
| `0` | The task finished, and did not return `:fail` |
| `1` | The task returned the symbol `:fail`; a usage error; a load or validation error; `Asgard::Error` was raised; a parallel dependency group had failures |
| The command's own status | A `sh` or `shebang` script exited non-zero: asgard exits with the same number |
| `127` | The interpreter a `shebang` names is not on `PATH` (`asgard: shell :lua not found: lua ...`) |
| `128 + N` | The script was ended by signal N (`143` after a TERM, `137` after a KILL), as a shell would report it |
| `130` | You pressed Ctrl-C |

A task that wants to report failure without stopping on the spot, the way asgard's own `*_check` quality gates do, returns `:fail`. Any other return value, including `:warn` and `:skip`, is a success. See [Dependencies](dependencies.md#passing-results-between-tasks) for passing results between tasks.

---

## `--debug` and `--verbose`

Both flags set a Ruby global before the task runs, which your tasks read through `debug?` and `verbose?` (see [Options & Flags](options.md#built-in-flags)). They also make asgard say a little more:

- `--verbose` prints each file an `import` loads from inside a task body: `import: /path/to/file.loki`.
- `--debug` with `--verbose` also prints `import: skip /path (already loaded)` and `import_up: name not found`.

Imports at the top of `.loki` run before the flags are read. To trace those, use Ruby's own warning switch or `--doctor`:

```bash
RUBYOPT=-w asgard build     # import: ... for every file as it loads
asgard --doctor             # the same chain, without running anything
```
