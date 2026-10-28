# Files & Directories

Everything asgard reads from and writes to disk: the files in your project, the per-project state it keeps outside the repository, the job files it hands to the system scheduler, and the temporary files a script runs from. Use this page when you want to know where something went, what is safe to delete, and what to back up.

---

## In Your Project

| File | Who writes it | Purpose |
|---|---|---|
| `.loki` | you | The project root marker and entry point. Asgard walks up from the current directory and loads the first `.loki` it finds. It may be empty. |
| `*.loki` | you | More task files, loaded only when `.loki` calls `import`. |
| `.env` (or any name) | you | Variables loaded by a `dotenv` call in a `.loki`. Never loaded unless asked. |
| `.envrc` | you | A direnv file. Scheduled and watched tasks run under `direnv exec` when direnv is on `PATH`, so these variables reach them at run time. |

Asgard writes nothing into the project directory itself. See [Task Files](task-files.md) and [Environment Variables](environment.md).

---

## The Project Slug

Every project's state is filed under a **slug**: the name of the directory holding `.loki`, a dash, and eight hex digits derived from the directory's full real path.

```
api-9f3a1c2b
watcher-examples-5e1d0c3a
```

The hash is what keeps two projects in directories of the same name apart: two checkouts called `api`, a repository and a fork beside it, two `examples/` directories. It is stable for as long as the project stays where it is, and it is the same whether you reach the project through a symlink or its real path.

To find a project's slug:

```bash
asgard schedule list --all    # Project: api-9f3a1c2b (/Users/you/work/api)
asgard watcher list --all
asgard jobs list --all
asgard watcher start          # started watcher for api-9f3a1c2b (pid 123); log: ...
```

Moving or renaming the project changes the slug. Its old schedules, watcher state and job records are then listed under the old slug as another project, flagged `[root missing]`; see [The Project Slug](schedule.md#the-project-slug), [Every Project at Once](schedule.md#every-project-at-once) and `asgard schedule prune` in the [Command Reference](commands.md#asgard-schedule).

---

## Per-Project State

Watcher state and background job records live under one state directory:

```
$XDG_STATE_HOME/asgard/          # default: ~/.local/state/asgard/
  watch/<slug>/
  jobs/<slug>/
```

Each `<slug>` directory is created readable by its owner only (mode 0700), because logs and job scripts can hold secrets. Each holds a `root` file naming the project directory, which is how the `list --all` commands find every project without loading its `.loki`.

### `watch/<slug>/`

| File | Contents |
|---|---|
| `watcher.pid` | The pid of the running watcher |
| `watcher.lock` | A lock the running watcher holds, so a second `watcher start` is refused |
| `watcher.log` | One line per trigger, spawn and exit, plus every triggered task's output |
| `watcher.log.1` | The previous log, once `watcher.log` grew past the limit (see [Log Rotation](#log-rotation)) |
| `declarations.json` | The `watch` declarations recorded at `start`, which `list --all` shows for other projects |
| `entries/<name>.json` | One record per entry with its last run: pid, status, duration, finish time |
| `changes/<name>-<n>.json` | A change list too large for the environment, handed to the task through `ASGARD_CHANGES_FILE` |
| `root` | The project directory |

See [Watched Files](watch.md#files-and-logs).

### `jobs/<slug>/`

| File | Contents |
|---|---|
| `<name>.json` | The job's record: name, owning task, pid, start time, working directory, script path, log path, first script line |
| `<name>.sh` | The script exactly as handed to the shell; the extension is the shell's (`.py` for `:python3`, and so on) |
| `<name>.log` | stdout and stderr of the job's latest run; emptied on each new start of that name |
| `<name>.status` | The exit status, written when the job ends |
| `root` | The project directory |

A job's files stay until the next start of the same name or `asgard jobs clean`, so the log of a crashed job can still be read. See [Background Jobs](jobs.md#files).

---

## Scheduler Files

`asgard schedule install` writes one job per declared entry into the system scheduler's own directory. The files are written readable by their owner only (mode 0600), since they carry the declaration's `env:` values.

=== "macOS (launchd)"

    | What | Where |
    |---|---|
    | Job definition | `~/Library/LaunchAgents/com.madbomber.asgard.<slug>.<name>.plist` |
    | Log | `~/Library/Logs/asgard/com.madbomber.asgard.<slug>.<name>.log` |

    `asgard schedule preview` prints the plist before anything is installed. A stopped entry is recorded by launchd itself (`launchctl print-disabled`), not in a file of asgard's.

=== "Linux (systemd)"

    | What | Where |
    |---|---|
    | Service unit | `$XDG_CONFIG_HOME/systemd/user/asgard.<slug>.<name>.service` (default `~/.config/systemd/user/`) |
    | Timer unit | `$XDG_CONFIG_HOME/systemd/user/asgard.<slug>.<name>.timer` |
    | Log | `$XDG_STATE_HOME/asgard/asgard.<slug>.<name>.log` (default `~/.local/state/asgard/`) |

    `asgard schedule preview` prints both units. Needs systemd 240 or later.

`asgard schedule list` ends with the log directory and the command that reads a log: `Logs: <dir>  (asgard schedule log NAME)`. See [Scheduled Tasks](schedule.md#how-jobs-run).

---

## Temporary Files

Every `sh` and `shebang` call writes its script to a file in the system temporary directory, named like `asgard_20261024-80545-bmbloc.sh` with the shell's extension, runs the shell on that file, and deletes it when the script ends. Two things follow:

- `$0` inside a script is that temporary path, not `bash` or a command name. Print a name you choose in usage messages.
- Nothing accumulates. There is nothing to clean up after a foreground script, even one that failed.

A background job's script is not temporary: it is kept as `jobs/<slug>/<name>.sh` so that `asgard jobs` can verify the job is still the process it started. See [Shell Commands](shell.md).

---

## Log Rotation

`watcher.log` is moved to `watcher.log.1` (replacing any older `.1`) once it is larger than 10 MB, and a fresh `watcher.log` starts. Set `ASGARD_LOG_MAX` to a number of bytes to change the limit:

```bash
ASGARD_LOG_MAX=1048576 asgard watcher start    # rotate at 1 MB
```

Job logs are not rotated; each new start of a job name empties its log. Scheduler logs are appended by launchd or systemd and are not rotated by asgard.

---

## What Is Safe to Delete

| Delete by hand | Safe? | Use instead |
|---|---|---|
| `jobs/<slug>/` files of a job that is not running | yes, but | `asgard jobs clean` removes exactly those |
| `watch/<slug>/watcher.log`, `watcher.log.1` | yes | a running watcher starts a fresh log on its next line |
| `watch/<slug>/entries/*.json` | yes | `list` then shows `never` for those entries |
| `watch/<slug>/` of a project whose watcher is **stopped** | yes | |
| `watch/<slug>/watcher.pid` or `watcher.lock` of a **running** watcher | **no** | `asgard watcher stop`; the watcher cannot be stopped or restarted cleanly without them |
| `jobs/<slug>/<name>.json` of a **running** job | **no** | `asgard jobs stop NAME`; without the record the job cannot be listed or stopped and must be found with `ps` |
| A plist or systemd unit | **no** | `asgard schedule remove NAME`, which also unloads the job from the scheduler |
| The whole `~/.local/state/asgard/` | only with every watcher stopped and every job stopped | |

The supported ways to tidy up are `asgard jobs clean`, `asgard schedule remove`, `asgard schedule prune` and `asgard watcher stop`. See the [Command Reference](commands.md).

---

## Environment Variables That Change Paths

| Variable | Default | Effect |
|---|---|---|
| `XDG_STATE_HOME` | `~/.local/state` | Base of the state directory (`<base>/asgard/`) and, on Linux, the scheduler logs |
| `XDG_CONFIG_HOME` | `~/.config` | Base of the systemd user unit directory (Linux) |
| `ASGARD_LOG_MAX` | `10485760` | Bytes before `watcher.log` rotates |

The full list of variables asgard reads and sets is in [Environment Variables](environment.md).
