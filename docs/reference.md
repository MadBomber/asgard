# DSL Reference

Every word you can write in a `.loki` file, on one page. Each entry gives the signature, what it does in one line, a one-line example, and a link to the guide page that explains it in full. Use this page to look something up; use the guide pages to learn it.

A `.loki` file is plain Ruby that reopens `class Tasks`. Asgard is built on Thor, so Thor's own DSL words (`desc`, `method_option`, `class_option`, `long_desc`, `map`, `subcommand`, `default_task`, `argument`, `no_commands`) work inside it, alongside asgard's own.

---

## Class-Level Words

These go inside `class Tasks ... end` (or inside a subcommand class), outside any method.

### Describing Tasks

| Word | Signature | Meaning | Example | Guide |
|---|---|---|---|---|
| `desc` | `desc "Description"` | Describe the next task; usage defaults to the method name | `desc "Run the tests"` | [Defining Tasks](tasks.md#basic-task) |
| `desc` | `desc "name ARG", "Description"` | Describe the next task with an explicit usage string | `desc "greet NAME", "Greet NAME"` | [Defining Tasks](tasks.md#positional-parameters) |
| `desc` | `desc "...", hide: true` | Describe the task but leave it out of `asgard help` | `desc "Ask first", hide: true` | [Defining Tasks](tasks.md#hidden-tasks) |
| `long_desc` | `long_desc "text"` | Extended help shown by `asgard help TASK`; `\x5` forces a line break | `long_desc <<~DESC ... DESC` | [Defining Tasks](tasks.md#extended-help-long_desc) |
| `default_task` | `default_task :name` | The task `asgard` runs with no arguments (help otherwise) | `default_task :build` | [Defining Tasks](tasks.md#default-task) |
| `map` | `map "alias" => "task"` | A second name for a task | `map "t" => "test"` | [Defining Tasks](tasks.md#command-aliases) |
| `argument` | `argument :name, type:, default:, desc:` | A positional argument for **every** task in the class | `argument :target, default: "localhost"` | [Defining Tasks](tasks.md#formal-argument-declaration) |

### Options

| Word | Signature | Meaning | Example | Guide |
|---|---|---|---|---|
| `method_option` / `option` | `option :name, aliases:, type:, default:, required:, desc:, enum:, banner:` | An option for the next task, read as `options[:name]` | `option :jobs, aliases: "-j", type: :numeric, default: 1` | [Options & Flags](options.md#per-task-options) |
| `class_option` | `class_option :name, ...` (same keys) | An option every task in the class accepts | `class_option :dry_run, type: :boolean` | [Options & Flags](options.md#class-options-shared-by-every-task) |
| `no_negate` | `no_negate :name, ...` | Hide `[--no-name]` and `[--skip-name]` from help for boolean class options | `no_negate :color` | [Options & Flags](options.md#boolean-class-options-and-no_negate) |

Option `type:` values: `:string`, `:boolean`, `:numeric`, `:array`, `:hash`.

### Dependencies

| Word | Signature | Meaning | Example | Guide |
|---|---|---|---|---|
| `depends_on` | `depends_on :a, :b` | Run `a`, then `b`, before the next task | `depends_on :build, :test` | [Dependencies](dependencies.md#sequential-dependencies) |
| `depends_on` | `depends_on [:a, :b]` | Run `a` and `b` at the same time, then the next task | `depends_on [:lint, :typecheck]` | [Dependencies](dependencies.md#parallel-dependencies) |
| `depends_on` | `depends_on :a, [:b, :c], :d` | Stages in order; an Array is one parallel stage | `depends_on :setup, [:lint, :build], :test` | [Dependencies](dependencies.md#mixed-sequential-and-parallel) |
| `depends_on` | `depends_on { [...] }` or `depends_on -> { [...] }` | Compute the stage list after every file has loaded | `depends_on { [all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)] }` | [Dependencies](dependencies.md#dynamic-dependencies) |

`depends_on` goes before the `def`, in either order with `desc`. It attaches to the very next method. A task that takes required arguments cannot be a dependency.

### Helpers and Help Text

| Word | Signature | Meaning | Example | Guide |
|---|---|---|---|---|
| `helper` | `helper(:name) { \|args\| ... }` | A method usable in the class body and inside tasks; never a command | `helper(:version) { File.read("VERSION").strip }` | [Helper Methods](helpers.md#the-helper-dsl-method) |
| `no_commands` | `no_commands do ... end` | Public methods inside the block are not commands | `no_commands { def sha = \`git rev-parse HEAD\`.strip }` | [Helper Methods](helpers.md#the-no_commands-block) |
| `private` | `private` | Methods after it are helpers, not commands | `private; def compile = sh "make"` | [Helper Methods](helpers.md#private-methods) |
| `header` | `header "text"` | Text above the command list in `asgard help` and `asgard tree`; calls append | `header "myapp build tasks"` | [Help & Diagnostics](diagnostics.md#header-and-footer) |
| `footer` | `footer "text"` | Text below the options in `asgard help` and `asgard tree`; calls prepend | `footer "Docs: https://example.com"` | [Help & Diagnostics](diagnostics.md#header-and-footer) |

!!! warning
    A public method with no `desc` is a **hidden task**: it runs from the command line and as a dependency, and `--doctor` lists it as hidden. Make helpers `private`, put them in `no_commands`, or define them with `helper`.

### Environment

| Word | Signature | Meaning | Example | Guide |
|---|---|---|---|---|
| `dotenv` | `dotenv(path = ".env")` | Load a dotenv file into the environment if it exists; earlier values win | `dotenv loki_up(".env") \|\| ".env"` | [Environment Variables](environment.md#loading-env-files-with-dotenv) |

### Shells

| Word | Signature | Meaning | Example | Guide |
|---|---|---|---|---|
| `shell` | `shell :name, "path [words]", args: nil, ext: nil` | Register a shell for `shebang`; returns the name | `shell :strict, "bash -eu -o pipefail"` | [Shell Commands](shell.md#shell-add-or-replace-an-entry) |
| `shell` | `shell "/path/to/exe -opts"` | Register under the executable's basename, options as args | `shell "/opt/homebrew/bin/bash"` | [Shell Commands](shell.md#shell-add-or-replace-an-entry) |
| `shell` | `shell :name` | Register `name` as itself from `PATH` | `shell :zsh` | [Shell Commands](shell.md#shell-add-or-replace-an-entry) |
| `default_shell` | `default_shell :name` | Select the shell used when `sh` or `shebang` names none (`:bash` until changed) | `default_shell :strict` | [Shell Commands](shell.md#default_shell-the-shell-used-when-none-is-named) |
| `default_shell` | `default_shell :name, "path", args:, ext:` | Register, then select | `default_shell :strict, "bash", args: "-eu -o pipefail"` | [Shell Commands](shell.md#default_shell-the-shell-used-when-none-is-named) |
| `default_shell` | `default_shell` | Returns the current default shell's name | `puts default_shell` | [Shell Commands](shell.md#default_shell-the-shell-used-when-none-is-named) |
| `shells` | `shells` / `Tasks.shells` | The registry: `name => { path:, args:, ext: }` | `shells[:bash] # => { path: "bash", args: [], ext: ".sh" }` | [Shell Commands](shell.md#the-shells-registry) |

Seeded shells: `:bash` `.sh`, `:sh` `.sh`, `:python3` `.py`, `:python` `.py`, `:node` `.js`, `:ruby` `.rb`, `:perl` `.pl`. A `shell` path is checked when the `.loki` loads; a bad one is an error naming the shell.

### Subcommands

| Word | Signature | Meaning | Example | Guide |
|---|---|---|---|---|
| `subcommand` | `subcommand "name", ClassName` | Mount a class that inherits from `Tasks` under `asgard name ...` | `desc "db SUBCOMMAND", "Database"; subcommand "db", DBCommands` | [Subcommands](subcommands.md) |

### Schedules

```ruby
schedule :task, at: "HH:MM", on: :daily, options: nil, env: {}, as: nil
schedule :task, every: SECONDS,          options: nil, env: {}, as: nil
```

| Keyword | Values | Meaning |
|---|---|---|
| `at:` | `"17:30"` or `%w[02:00 14:00]` | Clock time(s), 24-hour; exactly one of `at:`/`every:` |
| `on:` | `:daily` (default), `:weekdays`, `:weekends`, `:friday`, `%i[monday thursday]` | Which days an `at:` entry fires |
| `every:` | `3600`, or anything with `in_seconds` | Interval in seconds |
| `options:` | `"--format md -v"` or `%w[--format md]` | The task's own arguments, split like a shell |
| `env:` | `{ "KEY" => "value" }` | Variables added to the job |
| `as:` | `"name"` (letters, digits, `_ . -`) | The entry's name; defaults to the task, or task plus options slugged |

Example: `schedule :report, options: "--period week", at: "16:00", on: :friday`. Guide: [Scheduled Tasks](schedule.md).

### Watches

```ruby
watch :task, paths:, only: nil, ignore: nil, events: :all, debounce: 0.5, env: {}, as: nil
```

| Keyword | Values | Meaning |
|---|---|---|
| `paths:` | `"lib/**/*.rb"`, `"docs"`, `"Gemfile"`, `%w[lib test]` | What to watch, relative to the project root |
| `only:` | Regexp or Array of Regexps | A changed path must also match one of these |
| `ignore:` | Regexp or Array of Regexps | Paths to ignore, on top of the defaults |
| `events:` | `:all` (default), `:changed`, `:added`, `:removed`, or an Array | Which kinds of change count (`:modified` means `:changed`) |
| `debounce:` | seconds, default `0.5` | Quiet time after the last event before the task runs |
| `env:` | `{ KEY: "value" }` | Variables added to the task |
| `as:` | `"name"` (letters, digits, `_ . -`) | The entry's name; needed for a second watch of the same task |

Example: `watch :test, paths: %w[lib test], only: /\.rb\z/`. Guide: [Watched Files](watch.md).

---

## Inside a Task Body

| Word | Signature | Meaning | Example | Guide |
|---|---|---|---|---|
| `sh` | `sh "script", silent: false, background: nil` | Run the script under the default shell; returns `true`; a failure exits asgard with the command's status | `sh "bundle exec rake test"` | [Shell Commands](shell.md#sh-run-a-script-in-the-default-shell) |
| `sh` | `sh :name, "script", silent: false, background: nil` | Run the script with a registered shell (or any executable on `PATH`) | `sh :python3, "print('hi')"` | [Shell Commands](shell.md#shebang-any-interpreter) |
| `shebang` | `shebang ...` | The same method as `sh`, under its longer name; many authors use it for scripts in another language | `shebang :python3, "print('hi')"` | [Shell Commands](shell.md#shebang-any-interpreter) |
| `silent:` | `silent: true` | Do not echo the script (or the `started` line of a job) | `sh "rake build", silent: true` | [Shell Commands](shell.md#silent-mode) |
| `background:` | `background: true` | Start the script as a job named `<task>-<N>`; returns at once | `sh "mkdocs serve", background: true` | [Background Jobs](jobs.md#starting-a-job) |
| `background:` | `background: :name` or `"name"` | Start a job with that name (letters, digits, `_`) | `sh "bin/rails server", background: :api` | [Background Jobs](jobs.md#starting-a-job) |
| `options` | `options[:name]`, `options.name`, `options.name?` | The task's option values; the predicate form is `true` or `false` | `sh "rake" if options.verbose?` | [Options & Flags](options.md) |
| `dep_result` | `dep_result(:task)` | The return value of a direct dependency that already ran | `dep_result(:test_check) == :pass` | [Dependencies](dependencies.md#passing-results-between-tasks) |
| `dep_results` | `dep_results` | A Hash of every direct dependency's return value | `dep_results.values.all?(:pass)` | [Dependencies](dependencies.md#passing-results-between-tasks) |
| `changes` | `changes` | What the watcher saw change; every list is empty when run by hand | `changes.modified.each { \|f\| puts f }` | [Watched Files](watch.md#reading-the-changes) |
| `env` | `env(:name, default = nil)` | An environment variable, name upcased; raises `KeyError` when unset and no default | `env(:port, "3000")` | [Environment Variables](environment.md#reading-variables-with-env) |
| `debug?` | `debug?` | `true` after `--debug` | `sh "make V=1" if debug?` | [Options & Flags](options.md#-debug-and-verbose) |
| `verbose?` | `verbose?` | `true` after `--verbose` | `puts details if verbose?` | [Options & Flags](options.md#-debug-and-verbose) |
| `puts` | `puts "text"` | Print to standard output | `puts "done"` | |
| `abort` | `abort "message"` | Print the message to standard error and exit 1 | `abort "no Gemfile" unless File.exist?("Gemfile")` | [Dependencies](dependencies.md#when-a-dependency-fails) |
| `raise` | `raise Asgard::Error, "message"` | Stop asgard with `asgard: message`, exit 1 | `raise Asgard::Error, "aborted"` | [Dependencies](dependencies.md#when-a-dependency-fails) |
| `return :fail` | `:fail` as the task's last value | Asgard exits 1 when the task you typed returns `:fail` | `result ? :pass : :fail` | [Help & Diagnostics](diagnostics.md#exit-status) |

`background:` returns a job object with `name`, `task`, `pid` and `log`:

```ruby
job = sh "mkdocs serve", background: true
puts "#{job.name} is pid #{job.pid}; output in #{job.log}"
```

`changes` has five readers:

| Reader | Value |
|---|---|
| `changes.modified` | Array of changed paths, relative to the project root |
| `changes.added` | Array of created paths |
| `changes.removed` | Array of deleted paths |
| `changes.all` | Every path once, modified then added then removed |
| `changes.empty?` | `true` when the task was not started by the watcher |

---

## Anywhere in a `.loki` File

These work at the top level of the file, inside the class body, and inside task bodies.

| Word | Signature | Meaning | Example | Guide |
|---|---|---|---|---|
| `import` | `import "file.loki"` | Load a `.loki` file once, relative to the calling file | `import "build.loki"` | [Task Files](task-files.md#loading-files-with-import) |
| `import` | `import "*.loki"` | Load every match of a glob (never `.loki` itself); `**` recurses | `import "tasks/**/*.loki"` | [Task Files](task-files.md#loading-files-with-import) |
| `import_up` | `import_up "name.loki"` | Find the file in the current directory or an ancestor and load it; `false` if not found | `import_up "shared.loki"` | [Task Files](task-files.md#loading-files-found-up-the-tree-with-import_up) |
| `loki_up` | `loki_up(name = ".loki")` | Find any file up the tree; a `Pathname` or `nil`; does not load | `loki_up(".env")` | [Task Files](task-files.md#finding-files-with-loki_up) |
| `env` | `env(:name, default = nil)` | As above | `dotenv if env(:load_env, "1") == "1"` | [Environment Variables](environment.md) |
| `debug?` / `verbose?` | | As above | `import "debug.loki" if debug?` | [Options & Flags](options.md) |
| `Asgard::VERSION` | | The running asgard's version string | `header "asgard #{Asgard::VERSION}"` | |

`import` must be given a path ending in `.loki`. A named file that does not exist stops asgard with a one-line error; a glob that matches nothing is not an error.

---

## Names You Cannot Use

- **Names Thor uses internally.** Defining a task or helper called `shell`, `options`, `invoke`, `run`, `args`, `behavior`, `root`, `destination_root`, `action`, `in_root`, `inside` or `parent_options` (among others on Thor's reserved list), or after one of asgard's own helpers (`sh`, `shebang`, `env`, `import`, `import_up`, `loki_up`, `changes`, `debug?`, `verbose?`, `dep_result`, `dep_results`, `current_task`, `invoke_command`), stops asgard as the `.loki` loads, with the file and line. Pick another name. This is why the watcher's foreground command is spelled `asgard watcher run` while your own task cannot be named `run`.
- **Names beginning with `_`.** The underscore prefix is reserved for asgard's own built-ins. `asgard _anything` is refused as an unknown command, and a `.loki` must not define `_`-prefixed methods.
- **`schedule`, `watcher`, `jobs`.** You may define tasks with these names, but `asgard schedule`, `asgard watcher` and `asgard jobs` still run the built-ins.
- **A name defined twice.** The later `def` silently replaces the earlier one; `asgard --doctor` reports it. See [Task Files](task-files.md#task-name-overloading).

---

## Return Values and Exit Status

| What happens | Asgard exits with |
|---|---|
| The task you typed finishes normally | 0 |
| The task you typed returns the symbol `:fail` | 1 (`:warn`, `:skip` and every other value exit 0) |
| A `sh` or `shebang` script exits non-zero | that status, at once |
| A script is ended by a signal | 128 plus the signal number |
| The shell or interpreter cannot be found | 127 |
| `raise Asgard::Error, "msg"` or `abort "msg"` | 1, after printing the message |
| A usage error (missing argument, unknown task or option) | 1 |
| A `.loki` fails to load, or a dependency graph is invalid | 1, after one line of explanation |
| Ctrl-C | 130 |

A dependency's return value never stops the task that depends on it; only an exit, an `abort` or a `raise` does. Which one a dependency uses is your choice: return a result for the dependent to judge, or stop the chain when the dependency must succeed. Full detail in [Help & Diagnostics](diagnostics.md#exit-status) and [Dependencies](dependencies.md#when-a-dependency-fails).
