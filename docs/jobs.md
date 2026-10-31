# Background Jobs

A task can start a process that keeps running after the task, and after asgard itself, has finished: a documentation server, a database, an API under development. `sh "mkdocs serve", background: true` starts one as a **job**, and the built-in `asgard jobs` command lists, stops, restarts and cleans up every job the project has started.

Jobs are built in. There is nothing to install or require, and a job's shell comes from the same [`shells` registry](shell.md#the-shells-registry) a foreground script uses.

---

## The Shortest Example

```ruby
# .loki
class Tasks
  desc "Serve the documentation"
  def doc_server = sh "mkdocs serve", background: true
end
```

```bash
asgard doc_server
```

```
mkdocs serve
started doc_server-1 (pid 48213), log: /Users/you/.local/state/asgard/jobs/api-9f3a1c2b/doc_server-1.log
```

The prompt comes straight back; the server is running. Later, from any directory in the project:

```bash
asgard jobs
```

```
┌──────────────┬────────────┬───────┬─────────┬─────────────────────┬──────────────┐
│ JOB          │ TASK       │ PID   │ STATUS  │ STARTED             │ COMMAND      │
├──────────────┼────────────┼───────┼─────────┼─────────────────────┼──────────────┤
│ doc_server-1 │ doc_server │ 48213 │ running │ 2026-10-24 09:30:01 │ mkdocs serve │
└──────────────┴────────────┴───────┴─────────┴─────────────────────┴──────────────┘

State: /Users/you/.local/state/asgard/jobs
```

```bash
asgard jobs log doc_server-1        # what it has printed so far
asgard jobs stop doc_server-1       # stopped doc_server-1 (pid 48213)
```

---

## Three Ways a Script Runs

`sh` and `shebang` run a script in one of three modes. The first two are asgard's; the third is the shell's, and it is worth knowing what you give up when you use it.

<figure markdown>
--8<-- "docs/assets/images/script-modes.svg"
<figcaption>Foreground: asgard waits. Managed background: asgard records the job and can find it again. Detached: the shell hands the process off and asgard never hears of it.</figcaption>
</figure>

| Mode | How you ask for it | The task | When asgard exits | `asgard jobs` |
|---|---|---|---|---|
| Foreground | `sh "rake build"` | Waits for the script to finish before its next statement; a failure exits asgard with the script's status | The script has already finished | Nothing to manage |
| Managed background | `sh "mkdocs serve", background: true` | Continues at once with a job object in hand | The job keeps running | Lists, stops, restarts and cleans it |
| Detached | `sh "mkdocs serve &"` (or `nohup`, `setsid`, `disown` inside the script) | Continues at once with `true`; the shell has already exited | The process keeps running | Knows nothing about it |

### Foreground

The default. The script runs under the default shell, asgard waits for it, and the task moves on only when it has finished. A non-zero exit ends the asgard process with that status, so a failed step stops the pipeline. See [Shell Commands](shell.md).

```ruby
def build
  sh "rake build"        # the task waits here
  sh "rake test"         # and only then runs this
end
```

### Managed Background

`background: true` (or `background: :name`) starts the script as a job. The call returns at once with a job object, the task continues with its next statement, and the job runs on in its own session with its output in a log file. When asgard exits the job is still running, and it is still asgard's: its pid, log and owning task are recorded on disk, so a later `asgard jobs list` shows it, `asgard jobs stop` ends it, and `asgard jobs restart` runs its task again.

```ruby
def servers
  sh "docker compose up postgres", background: true   # servers-1
  sh "bin/rails server",            background: :api  # api
  puts "both up; see `asgard jobs list`"               # runs immediately
end
```

### Detached

A trailing `&`, or `nohup`, `setsid` or `disown` inside the script, hands the process to the shell's own background handling. It runs in the background much like a managed job, with two differences that matter:

- **No management data is saved.** The shell exits without waiting, asgard sees that clean exit and reports the step as a success, and nothing records the pid, the log or the task. `asgard jobs` cannot list, stop, restart or clean it. Running the task again starts a second copy. An error after the `&`, even a misspelled command, is invisible to asgard.
- **It is detached from asgard completely.** The process is reparented to the system when asgard exits, and you manage it some other way: `ps`, `pgrep`, `kill`, or whatever the program itself offers. Unless the script redirects them, its stdout and stderr are still your terminal, so its output keeps landing on top of your prompt after asgard has returned, and Ctrl-C at that prompt no longer reaches it.

Detaching is the right tool when you really do want a process asgard should never touch. For anything you expect to come back to, use `background:`.

```ruby
# Detached: asgard reports success and forgets it exists.
def docs_detached = sh "nohup mkdocs serve > mkdocs.log 2>&1 &"

# Managed: listed, logged, stoppable, restartable.
def docs = sh "mkdocs serve", background: true
```

---

## Starting a Job

`sh` and `shebang` both take `background:`:

```ruby
class Tasks
  desc "Serve the documentation"
  def doc_server = sh "mkdocs serve", background: true

  desc "Bring up the development stack"
  depends_on :db
  def servers
    sh "bin/rails server", background: :api
    shebang :python3, "import http.server; http.server.test()", background: :static
  end

  desc "Start the database"
  def db = sh "postgres -D tmp/db", background: true
end
```

| `background:` | Job name | Notes |
|---|---|---|
| `nil` or `false` | none | Foreground; the default |
| `true` | `<task>-<N>` | Named after the task whose body made the call, plus a counter: `doc_server-1`, `servers-1`, `servers-2`. Must be called from inside a task. A `?`, `!` or `=` in the task name is spelled `-q`, `-b` or `-e` (`ready?` gives `ready-q-1`), so no two tasks share a job name |
| a Symbol or String | the name itself | Letters, digits and `_` only; never looks like an automatic name |
| anything else | | `ArgumentError` |

The counter restarts at 1 each time a task body runs, so re-running `servers` while `servers-1` is still up names the second call `servers-2` again, and a dependency running in a parallel stage names its jobs after itself (`db-1`), not after the task you typed. Named jobs never consume a number: `true`, `:api`, `true` yields `servers-1`, `api`, `servers-2`, so adding or removing a named job never renumbers the rest. Job names are unique per project across tasks; two tasks that both say `background: :server` share one slot.

The call echoes the script as usual, then prints one line and returns:

```
mkdocs serve
started doc_server-1 (pid 48213), log: /Users/you/.local/state/asgard/jobs/api-9f3a1c2b/doc_server-1.log
```

The return value is a job object with `name`, `task`, `pid` and `log`, in case the task wants to print or wait on something. `silent: true` suppresses both the echo and the `started` line.

### Already Running

Starting a job whose name is already running starts nothing. The call prints `doc_server-1 already running (pid 48213, started by doc_server), log: <path>` and returns the existing job. A job whose record is on disk but whose process is gone is replaced: the old record, script and status are removed, the log is emptied, and the new process starts.

### Failure

A missing shell exits 127 up front, as foreground `sh` does, because nothing would otherwise be watching for it. Every other failure happens after the call has returned and shows up in the listing as an exit status, and in the log. There is no automatic rollback; jobs already started by the same task body stay up.

### The Job's Environment

The job inherits the task's environment plus `ASGARD_JOB` (its name) and `ASGARD_JOB_STATUS` (the file its exit status is written to). `PYTHONUNBUFFERED=1` is set unless you set it yourself, because Python fully buffers stdout when it is a file and a `print` loop would otherwise show nothing in the log until exit. See [Environment Variables](environment.md).

---

## Managing Jobs

```bash
asgard jobs                   # same as list
asgard jobs list              # this project's jobs: running, exited with a status, or gone
asgard jobs list --all        # every project's, grouped by project
asgard jobs stop              # stop every job of this project
asgard jobs stop api          # stop one job by name
asgard jobs stop servers      # stop every job started by a task, and by the tasks it depends on
asgard jobs stop --all        # stop every project's jobs
asgard jobs stop api -t 30    # wait 30s after TERM before KILL (default 10)
asgard jobs log api           # print the log
asgard jobs log api -f        # follow it (tail -f)
asgard jobs restart api       # stop it, then run its owning task again
asgard jobs clean             # forget every job that is no longer running
```

### list

One row per job with its name, owning task, pid, status, start time and the first line of its script:

```
┌──────────────┬────────────┬───────┬─────────────────┬─────────────────────┬───────────────┐
│ JOB          │ TASK       │ PID   │ STATUS          │ STARTED             │ COMMAND       │
├──────────────┼────────────┼───────┼─────────────────┼─────────────────────┼───────────────┤
│ db-1         │ db         │ 48201 │ running         │ 2026-10-24 09:30:01 │ postgres -D … │
│ api          │ servers    │ 48213 │ exited 1 (2.5s) │ 2026-10-24 09:30:02 │ bin/rails se… │
│ doc_server-1 │ doc_server │ 47990 │ gone            │ 2026-10-23 17:12:40 │ mkdocs serve  │
└──────────────┴────────────┴───────┴─────────────────┴─────────────────────┴───────────────┘

State: /Users/you/.local/state/asgard/jobs
```

| Status | Meaning |
|---|---|
| `running` | The recorded pid is alive and is still the process asgard started |
| `exited N (Ns)` | The job ended with status N after that long; 143 is a TERM, 137 a KILL by `asgard jobs stop` |
| `exited N (Ns, processes left)` | The script ended, but processes it started (a `server &` line, say) still run in the job's process group. `stop` still reaches them, and `clean` keeps the job until they are gone |
| `gone` | Neither: the process is not there and no status was written. The machine rebooted, or something outside asgard killed the job outright |

Run from a directory with no `.loki` above it, `list` covers every project, as `--all` does. A file in the state directory that is not a job's record (a hand edit, a disk that filled up) is left out of the table with a note on stderr, `jobs: skipped <path>: not a job record`, and `clean` removes it. With no jobs recorded:

```
No jobs recorded for api-9f3a1c2b. Start one with `sh "...", background: true` inside a task.
Use `asgard jobs list --all` to see every project's jobs.
```

### stop

Each name is first tried as a job name, then as a task name: `stop servers` ends every job that `servers` started and, through `depends_on`, every job its dependencies started (`db-1`). Resolving a task name reads the project's `.loki`, so that form works inside the project. No name stops every job of the project; `--all` stops every project's. Jobs stop newest first.

Each job gets `TERM` to its whole process group, so the shell and everything it started go together, including processes the script left behind when it exited. After a second of waiting the command says so, and when the grace period runs out (`--timeout`, default 10 seconds) it sends `KILL`, waits until the group is empty, and records status 137 so `list` shows `exited 137`. One line per job:

```
stopped api (pid 48213)
waiting for db-1 (pid 48201)
killed db-1 (pid 48201) after 10s
doc_server-1 is not running
```

A task that exists but has no jobs on record prints `servers has no running jobs`. The exit status is 1 when any job had to be killed or any name matched neither a job nor a task (`jobs: no such job or task: apii`). Records stay, so the log of a stopped job can still be read; `clean` removes them.

### log

Prints the job's log, stdout and stderr together, from its latest start (each start empties it). `-f` follows it as `tail -f` does. A job that has not written yet still has an empty log.

### restart

Stops the job, then runs its owning task again in the same asgard process, dependencies included. A job started with a chosen name from outside a task body has no owning task and cannot be restarted: `jobs: static was not started from a task, so there is nothing to run again`.

### clean

Removes the record, script, status and log of every job that is not verified running, and prints `removed NAME` for each. Nothing that is running is touched, and neither is a job whose script exited while processes it started still run. A job started again while `clean` runs keeps its fresh record. With nothing to do: `Nothing to clean for api-9f3a1c2b.`

---

## How a Job Runs

A job starts in a **new session** of its own: it has no controlling terminal, so closing the terminal that started it does not reach it, and it leads its own process group, which is what `stop` signals as a whole so the shell and everything it started go together.

The recorded pid belongs to a small `/bin/sh` wrapper that runs your script's shell as its child, waits for it, and writes the exit status to a status file when it ends. That is how `list` can show `exited 1 (2.5s)` for a job nobody was waiting on. The wrapper is always `/bin/sh`, whatever your `default_shell` is; your script still runs under the shell you asked for. Because the recorded pid is the wrapper, an `exec` inside your script replaces only the inner shell and the job stays verifiable.

The wrapper deliberately outlasts a `TERM` so it can write the status, so `kill 48213` on the pid that `started` and `list` show does nothing to the job. Stop a job with `asgard jobs stop`, or signal its whole process group yourself with `kill -- -48213` (the leading `-` addresses the group).

The job's stdin is `/dev/null`, so it can never stop waiting for keyboard input, and its stdout and stderr are appended to the log.

A job is **verified**, not assumed, every time asgard looks at it: the pid must be alive and its command line must still carry the job's script path. A pid reused by an unrelated process after a reboot fails that check and the job shows as `gone` rather than as somebody else's process. Processes left in the group after the script exited count only if they started before it exited, so a process group that later reuses the number is never mistaken for the job.

Verifying uses `ps -ww -o ... -p PID`, which the system `ps` on macOS and BSD and the procps `ps` on Linux accept. BusyBox `ps`, the default on Alpine, rejects those options; there a `background:` start, and every `asgard jobs` command that looks at a job, stops with an error that says so instead of treating every job as gone and starting duplicates. Install procps (`apk add procps`) to use jobs there.

---

## Files

Everything lives under `~/.local/state/asgard/jobs/<slug>/` (or `$XDG_STATE_HOME/asgard/jobs/<slug>/`), where the slug is the project directory's name plus a short hash of its full path, the same slug [schedules](schedule.md#the-project-slug) and [watchers](watch.md#files-and-logs) use:

| File | Contents |
|---|---|
| `<name>.json` | The record: name, task, pid, start time, working directory, script path, log path, first script line |
| `<name>.sh` (or the shell's extension) | The script exactly as handed to the shell |
| `<name>.log` | stdout and stderr of the latest run |
| `<name>.status` | The exit status, written when the job ends (or 137, by `stop` after a `KILL`) |
| `root` | The project root, so `list --all` can find every project without loading its `.loki` |

The directory is readable by you alone, since logs and scripts can hold secrets. A job's files stay until the next start of that name or `asgard jobs clean`, so the log of a crashed job can still be read. A new start of the same name removes the old record, script and status and empties the log; `clean` deletes all four.

---

## Patterns

**A development stack.** Give each server a name, put the database in a dependency, and one command brings everything up:

```ruby
class Tasks
  desc "Start the database"
  def db = sh "postgres -D tmp/db", background: :db

  desc "Bring up the whole development stack"
  depends_on :db
  def servers
    sh "bin/rails server -p 3000", background: :api
    sh "bin/vite dev",             background: :assets
    sh "mkdocs serve",             background: :docs
  end
end
```

```bash
asgard servers            # db, api, assets, docs
asgard jobs               # all four, running
asgard jobs stop servers  # all four, including db, because servers depends on db
asgard jobs restart api   # just the API, by running servers again (db is already up, so it is reused)
```

**A one-word stop.** `asgard jobs stop servers` is the normal way down. A task may wrap it when you want a name of your own:

```ruby
desc "Stop the development stack"
def down = sh "asgard jobs stop servers"
```

**Jobs from watchers and schedules.** A task run by the [watcher](watch.md) or by a [schedule](schedule.md) may start jobs. They are recorded under the project's slug like any other, so `asgard jobs` from the project directory shows them as if you had started them by hand.

---

## Jobs, Watchers and Schedules

The three built-ins answer different questions:

- A **job** is a process a task starts on purpose, by name, that outlives asgard. It is not a supervisor: a job that crashes stays down and shows as exited until you restart it.
- A **[watcher](watch.md)** runs tasks when files change.
- A **[schedule](schedule.md)** runs tasks on a timer.

They compose. A task run by the watcher or by a schedule may start jobs; the records are on disk under the project's slug, so they are visible to `asgard jobs` from the project directory.

---

## Name Collisions

The built-in command is registered under a reserved name and mapped to `jobs`. If your `.loki` defines its own task called `jobs`, `asgard jobs` still runs the built-in; name your task something else.
