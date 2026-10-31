# Command Reference

Everything you can type after `asgard`, on one page. The first section covers running your own tasks; the three after it cover the built-in commands `schedule`, `watcher` and `jobs`. Each table row is one line; the guide pages linked from each section go deeper.

---

## Running Tasks

```
asgard TASK [ARGUMENTS] [--option VALUE ...] [--debug] [--verbose]
```

Asgard looks for a `.loki` file in the current directory, then in each parent directory, and loads the first one it finds. Without one it stops: `asgard: no .loki file found in /path`. The three `list` commands below and bare `asgard jobs` are the exceptions; they work anywhere and then cover every project on the machine.

| Command | What it does |
|---|---|
| `asgard` | Runs the `default_task` if the project set one, otherwise shows help |
| `asgard TASK` | Runs `TASK`, its dependencies first |
| `asgard TASK ARG...` | Passes positional arguments to the task's method parameters |
| `asgard TASK --opt VALUE` | Sets an option declared with `option` or `class_option` |
| `asgard help` | Lists every task with its description, plus the project's header and footer |
| `asgard help TASK` | Usage, options and `long_desc` for one task |
| `asgard tree` | The tasks as a tree, subcommands expanded |
| `asgard --version` | Prints the version and exits; works without a `.loki` |
| `asgard --doctor` | Prints the diagnostic report and exits; works even when the `.loki` is broken |
| `asgard TASK --debug` | Runs the task with `debug?` true |
| `asgard TASK --verbose` | Runs the task with `verbose?` true; an `import` inside the task prints what it loads |

`--version` and `--doctor` are asgard's own only before the task name. After it they belong to the task: `asgard mytask --version` hands `--version` to `mytask`.

### Prefix Matching and Aliases

Any unambiguous prefix of a task name runs it. An exact name always wins over a longer name it is a prefix of. An ambiguous prefix stops with a list of candidates.

```bash
asgard ru          # runs rubocop_check if it is the only task starting with "ru"
asgard test        # runs test, even though test_check also exists
asgard dep         # Ambiguous command dep matches [deploy, deploy_staging]
```

A `map "t" => "test"` in the `.loki` adds a name that stays stable whatever tasks are added later. See [Defining Tasks](tasks.md#command-aliases).

### Built-in Flags

| Flag | Effect |
|---|---|
| `--debug` | `debug?` is true inside tasks; with `--verbose`, an `import` inside the task also reports files it skips |
| `--verbose` | `verbose?` is true inside tasks; an `import` inside the task prints each file it loads |
| `--version` | Print the version and exit |
| `--doctor` | Print the diagnostic report and exit |

See [Options & Flags](options.md#built-in-flags) and [Help & Diagnostics](diagnostics.md).

---

## `asgard schedule`

Manages the entries declared with `schedule :task, ...` in the `.loki`. The scheduler is launchd on macOS and systemd user timers on Linux. Guide: [Scheduled Tasks](schedule.md).

| Command | Arguments and flags | What it does |
|---|---|---|
| `asgard schedule preview` | | Prints the job files `install` would write, without writing them |
| `asgard schedule install` | | Installs every declared entry and removes this project's entries that are no longer declared; prints `installed NAME: asgard task args (17:30 weekdays)` per entry |
| `asgard schedule list` | `--all`, `-a` | A table of this project's installed entries (NAME, COMMAND, SCHEDULE, STATE, LAST EXIT); `--all` covers every project, grouped by `Project: slug (/path)` |
| `asgard schedule stop NAME` | | Stops one entry; it stays stopped across reboots and reinstalls until started |
| `asgard schedule start NAME` | | Starts a stopped entry, or installs and starts just this one declared entry |
| `asgard schedule trigger NAME` | | Runs an installed entry now, under the scheduler; refused while the entry is stopped |
| `asgard schedule log NAME` | `--follow`, `-f` | Prints the entry's log; `-f` keeps printing as output arrives |
| `asgard schedule remove` | `[NAME]` | Removes one installed entry, or every entry of this project |
| `asgard schedule prune` | `--dry-run`, `-n` | Removes every project's entries whose project directory no longer exists; `-n` only lists them |

STATE is `active`, `running`, `stopped` or `not loaded`. LAST EXIT is the exit code, `never run`, or `-` for a stopped entry.

**Naming another project's entry.** `stop`, `start`, `trigger`, `log` and `remove` accept `project/NAME`, where `project` is the slug shown by `list --all` or just the project's directory name when that is enough to pick it out. A bare `NAME` means this project's entry first, then any other project's; when two other projects share the name, asgard asks you to write `project/NAME`.

Run `install` again after changing a declaration or your `PATH`.

---

## `asgard watcher`

Runs and manages the file watcher for the entries declared with `watch :task, paths: ...`. One watcher process per project. Guide: [Watched Files](watch.md).

| Command | Arguments and flags | What it does |
|---|---|---|
| `asgard watcher start` | | Starts the watcher in the background; prints `started watcher for <slug> (pid N); log: <path>`; refused if one is running |
| `asgard watcher stop` | `--force`, `-f` | Stops the watcher; a task already running finishes first, and `stop` names it while it waits. `--force` ends running tasks (TERM, then KILL after five seconds) instead of waiting |
| `asgard watcher list` | `--all`, `-a` | A table of this project's watches (NAME, TASK, WATCHES, DAEMON, LAST RUN); `--all` covers every project |
| `asgard watcher preview` | | Prints the exact command and environment each entry would run |
| `asgard watcher log` | `--follow`, `-f` | Prints the watcher's log; `-f` keeps following it |
| `asgard watcher run` | | Watches in the foreground until Ctrl-C or TERM; this is what `start` runs detached. `asgard tree` lists it as `daemon`, and `asgard watcher daemon` is the same command |

DAEMON is `running` or `stopped`. LAST RUN is `never`, `running (pid N)`, `did not finish (pid N)`, or the exit status with duration and time, such as `0 (0.4s, 2026-10-18 23:40:02)`.

Saving a loaded `.loki` file while the watcher runs restarts it with the new declarations.

---

## `asgard jobs`

Lists, stops and restarts the background jobs started with `sh "...", background: true` (or `background: :name`). Guide: [Background Jobs](jobs.md).

| Command | Arguments and flags | What it does |
|---|---|---|
| `asgard jobs` | | Same as `list` |
| `asgard jobs list` | `--all`, `-a` | A table of this project's jobs (JOB, TASK, PID, STATUS, STARTED, COMMAND); `--all` covers every project |
| `asgard jobs stop` | `[NAME...]`, `--all` / `-a`, `--timeout N` / `-t N` | Stops jobs by job name, or by task name (including jobs its dependencies started); no name stops every job of this project; `--all` stops every project's; TERM first, KILL after `N` seconds (default 10) |
| `asgard jobs log NAME` | `--follow`, `-f` | Prints the job's log (stdout and stderr of its latest run); `-f` follows it |
| `asgard jobs restart NAME` | `--timeout N` / `-t N` | Stops the job, then runs its owning task again, dependencies included |
| `asgard jobs clean` | | Forgets every job that is no longer running: record, script, status and log |

STATUS is `running`, `exited N (2.5s)` or `gone` (the process is not there and no exit status was recorded, as after a reboot).

`stop` prints one line per job: `stopped api (pid 48213)`, `killed db-1 (pid 48201) after 10s`, or `doc_server-1 is not running`. It exits 1 when any job had to be killed or any name matched nothing. `stop --all` takes no names.

---

## Working Outside a Project

These commands do not need a `.loki` above the current directory. Run from anywhere, they cover every project on the machine:

```bash
asgard schedule list
asgard watcher list
asgard jobs list
asgard jobs
```

Every other command needs a project, because it reads the project's `.loki` to know its tasks and declarations.

---

## Exit Status

| Condition | Status |
|---|---|
| Task finished normally | 0 |
| Task returned `:fail` | 1 |
| A `sh` or `shebang` script failed | the script's exit status |
| A script was ended by a signal | 128 + the signal number |
| Shell or interpreter not found | 127 |
| `abort` or `raise Asgard::Error` in a task | 1 |
| Usage error: missing argument, unknown task, unknown option | 1 |
| No `.loki` found, a `.loki` failed to load, or a dependency graph is invalid | 1 |
| `asgard jobs stop` had to kill a job, or a name matched nothing | 1 |
| Ctrl-C | 130 |

Details and the messages that go with each case are in [Help & Diagnostics](diagnostics.md#exit-status).
