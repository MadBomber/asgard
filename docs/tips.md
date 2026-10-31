# Tips

Short, practical advice gathered from using asgard day to day. Each tip stands on its own; skim the bold phrases and read the ones that fit your project. Where a tip touches a feature in depth, it links to the page that covers it.

---

## Getting Started

- **Start from working files.** The task files at the repository root (`.loki`, `quality.loki`, `gem_tasks.loki`, `git.loki`, `doc_tasks.loki`) are a real multi-file project: quality gates that return `:pass` or `:fail`, a background job, a subcommand group, a `helper` feeding the `header`, and a deliberate override for `--doctor`. Copy what fits. See [The asgard Repository Itself](examples.md#the-asgard-repository-itself).

- **More examples.** [MadBomber/dev](https://github.com/MadBomber/dev) holds shared `.loki` libraries used across many repos: gem, git, Rails quality, schedule, status report and iTerm tasks. The [Examples](examples.md) page walks through the repository's `examples/` directory, one small file per feature.

- **One setup for every project.** Put the tasks, shells and helpers you want everywhere in `~/.loki`, then start each project's `.loki` with `import "~/.loki"`. Outside any project the same file is found by the walk up the tree, so those tasks work in any directory. See [Task Files](task-files.md).

---

## Naming and Running Tasks

- **Give busy tasks a short name with `map`.** `map "t" => "test"` stays stable when a later task would otherwise make the prefix `t` ambiguous. Thor's prefix matching is handy; an alias is dependable. See [Defining Tasks](tasks.md).

- **Make bare `asgard` do the common thing.** `default_task :test` (or `:quality`, as this repository does) saves typing on the task you run most.

- **Flags go after the task name.** `asgard build --verbose` runs the task; `asgard --verbose build` prints the help for `build`. Only `--version` and `--doctor` go first. See [Options & Flags](options.md).

---

## Organizing Many Tasks

- **One command group per file, named for the file.** When a project outgrows a flat list of tasks, give each area its own `<name>.loki` that defines exactly one top-level command with its tasks as subcommands: `box.loki` ends with `subcommand "box", BoxCommands` and gives you `asgard box up`, `asgard box logs`, `asgard box console`; `prod.loki` gives you `asgard prod info`; and so on for `db`, `jira`, `stage`, `branch`. The bare `.loki` is the marker, starts with `import "*.loki"`, and keeps only the tasks that have to stay top-level: a `watch` target (a watcher can only run a top-level task) and `*_check` gates that `quality` finds by name. `asgard help` then lists a dozen groups instead of a hundred tasks, and `asgard box help` shows one area at a time. Write the convention down in a comment at the top of `.loki` so the next file follows it. See [Subcommands Across Files](subcommands.md#subcommands-across-files).

- **Put a one-word wrapper for each group in `bin/`.** Two lines of shell drop the `asgard` from every command you type all day:

    ```sh
    #!/usr/bin/env sh
    # Shortcut for `asgard box ...` — passes every argument and option through.
    exec asgard box "$@"
    ```

    Now `box up`, `box logs`, `prod info --web` and `jira 166` are complete commands; every argument and flag passes straight through, so `box help` still works. A wrapper can go one level deeper for the thing you do most: `bin/work` is `exec asgard branch working "$@"`, so `work 168` points the working clone at a ticket's branch. Put the wrappers on `PATH` only inside the project with [direnv](https://direnv.net) (`brew install direnv`): it reads a `.envrc` in the project root as you `cd` in and undoes everything as you leave, so one line, `PATH_add bin`, makes `box` mean this project's box here and nothing (or something else) in the next directory over. The same `.envrc` is the natural home for the project's environment variables, and asgard's watchers and schedules load it too; see [`.envrc` and direnv](environment.md#envrc-and-direnv). `bin/` stays an ordinary `bin/`, so a real script, such as a report generator, lives there beside the wrappers.

- **Alias inside a group, too.** Thor's prefix matching works on subcommands, so `box co` runs `console` until a `commit` task arrives; `box st` is already ambiguous between `start`, `status` and `stop`. Inside the group class, `map "start" => "up", "c" => "console"` gives the subcommands you type most a name that cannot drift. See [Command Aliases](tasks.md#command-aliases).

---

## Seeing What You Have

- **See the tasks by file with `asgard --doctor`.** It lists every `.loki` file that loaded and, under each, the tasks that file defines with their line numbers, plus which `.loki` won the walk up the tree, what every `import` loaded, tasks hidden because they lack a `desc`, and definitions silently replaced by a later one. It works even when the `.loki` will not load. See [The Doctor Report](diagnostics.md#the-doctor-report).

- **See the commands as a tree with `asgard tree`.** Every command with its description, each subcommand group expanded under its own heading, header and footer included. `help` shows what you can type; `tree` shows how it is organised. See [`asgard tree`](diagnostics.md#asgard-tree).

- **Trace loading when something is missing.** `RUBYOPT=-w asgard help` prints each file as `import` loads it; `ASGARD_TRACE=1` turns a one-line load error into the full backtrace with Ruby's "Did you mean?" hint. See [Tracing Imports](task-files.md#tracing-imports) and [Load Errors](diagnostics.md#load-errors).

---

## Helpers and Dependencies

- **Keep helpers out of the command list.** A public method without a `desc` is a hidden task: it runs from the command line and as a dependency. Make helpers `private`, wrap them in `no_commands`, or define them with `helper`. See [Helper Methods](helpers.md).

- **Pass results, not instance variables.** Parallel dependencies each run on their own copy of the task object, so an `@ivar` set in one never reaches the task that depends on it. Return a value and read it with `dep_result(:name)` or `dep_results`; [`bad.loki`](examples.md#badloki) shows the trap. See [Dependencies](dependencies.md).

- **Let gates report, let guards stop.** A quality gate returns `:fail` so every gate runs and the summary shows all failures at once. A guard such as [`confirm.loki`](examples.md#confirmloki) raises `Asgard::Error` so nothing after it runs. A dependency's return value never stops its dependent; only an exit, `abort` or `raise` does.

- **Import conditionally.** `.loki` is plain Ruby: `import "quality_rails.loki" if ENV["RAILS_ROOT"]` keeps Rails-only gates out of non-Rails projects, and a block-form `depends_on` picks up whatever `*_check` tasks are loaded. See [Loading Patterns](task-files.md#loading-patterns).

---

## Shells and Processes

- **Name shell configurations, not shells.** The name you give `shell` is yours: `shell :strict, "bash -eu -o pipefail"` names a bash configuration that stops at the first failing line, and `shell :uv, "uv run --script", ext: ".py"` names a way of running Python. `sh` and `shebang` take a name as an optional first argument (`sh :strict, "..."`); without one they run the `default_shell`, so `default_shell :strict` makes every plain `sh` fail fast. See [The `shells` Registry](shell.md#the-shells-registry).

- **An AI agent is just another shell.** Register a coding agent's CLI with `shell` and a heredoc becomes the prompt: [`examples/robots/.loki`](https://github.com/MadBomber/asgard/blob/main/examples/robots/.loki) wires up `claude -p` in one line, and its `ask` task sends a prompt with a plain `sh :claude, <<~PROMPT`. Any agent that reads a prompt from stdin fits the same way, so a task can review a diff, draft release notes or explain a failing test alongside the tasks that run them.

- **Prefer `background: true` to a trailing `&`.** A managed job gets a name, a log and `asgard jobs stop`; a process detached with `&` leaves no record and must be found with `ps`. See [Background Jobs](jobs.md).
