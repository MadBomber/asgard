# Environment Variables

Tasks read configuration from the environment all the time: a port, a deploy target, an API key. This page covers how a task reads a variable, how a project loads a `.env` file, and then the part that is easy to miss: the variables asgard itself sets for the processes it starts, and the few it reads.

The short version:

```ruby
class Tasks
  dotenv                     # load .env, if there is one

  desc "Start the server"
  def start = sh "puma -p #{env(:port, '3000')}"
end
```

```bash
asgard start               # puma -p 3000
PORT=8080 asgard start     # puma -p 8080
```

---

## Reading Variables with `env`

`env` fetches an environment variable by name. The name may be a symbol or a string, and it is upcased for you, so `env(:port)` and `env("PORT")` are the same call.

| Call | Behaviour |
|---|---|
| `env(:port, "3000")` | The value of `PORT`, or `"3000"` when it is unset |
| `env(:api_key)` | The value of `API_KEY`; raises `KeyError` when it is unset |
| `env("DATABASE_URL")` | A string name works the same way |
| `env("database_url")` | Lower case is upcased: still `DATABASE_URL` |

Use the no-default form for anything a task cannot run without. The error names the variable, and asgard stops before the task does half its work:

```ruby
class Tasks
  desc "Deploy the app"
  def deploy = sh "cap #{env(:deploy_target)} deploy"
end
```

```bash
asgard deploy
```

```
...:in 'fetch': key not found: "DEPLOY_TARGET" (KeyError)
	from ...
	from /Users/you/myproject/.loki:3:in 'Tasks#deploy'
	...
```

The `KeyError` is not caught, so it arrives as Ruby's usual message and backtrace, and asgard exits 1. The first line names the variable; the first line that points into a `.loki` file is the call. For a one-line message instead, check the variable yourself and `raise Asgard::Error, "set DEPLOY_TARGET first"`; see [Help & Diagnostics](diagnostics.md#runtime-errors).

!!! note
    Environment values are always strings. Convert where it matters: `env(:port, "3000").to_i`, `env(:debug, "false") == "true"`.

`env` is available everywhere in a `.loki` file: in task bodies, in helpers, and in the class body (`@@host ||= env(:host, "localhost")`).

---

## Loading `.env` Files with `dotenv`

`dotenv` loads a file of `KEY=value` lines into the environment before any task runs. Call it in the class body, not inside a task:

```ruby
class Tasks
  dotenv                  # loads .env

  desc "Print the app name from .env"
  def check = puts env(:app_name)
end
```

```bash
# .env
APP_NAME=myapp
DATABASE_URL=postgres://localhost/myapp_development
REDIS_URL=redis://localhost:6379/0
PORT=3000
```

### A Named File, or Several

```ruby
class Tasks
  dotenv                  # .env: shared defaults
  dotenv ".env.local"     # per-machine values
end
```

Each call adds the variables it finds. A variable that is already set, by an earlier `dotenv` call or by your shell, is **never overwritten**. That is the standard dotenv rule, and it means your shell always has the last word: `PORT=8080 asgard start` beats whatever `.env` says.

### A Missing File Is Not an Error

`dotenv` checks that the file exists and does nothing when it does not. A `.loki` can name `.env.local` without requiring every developer to create one.

### From Any Subdirectory

The path is relative to the directory you ran asgard from, not to `.loki`. Run `asgard start` from `src/app/` and a bare `dotenv` looks for `src/app/.env`, finds nothing, and silently loads nothing. Ask for the nearest `.env` up the tree instead:

```ruby
class Tasks
  dotenv loki_up(".env") || ".env"
end
```

`loki_up(".env")` returns the first `.env` found in the current directory or any ancestor, and the `|| ".env"` keeps the usual no-op behaviour when there is none. See [Task Files](task-files.md#finding-files-with-loki_up).

### File Format

Standard dotenv syntax: one `KEY=value` per line, `#` comments, quoted values when a value has spaces, and `${OTHER}` to reference another variable. Multi-line values are supported as the dotenv gem documents them.

---

## One Value, Several Tasks

When several tasks read the same variable, read it once in a private helper so the default lives in one place:

```ruby
class Tasks
  dotenv

  desc "Start the server"
  def start = sh "puma -p #{port}"

  desc "Show the configuration"
  def config = puts "listening on #{port}"

  private

  def port = env(:port, "3000").to_i
end
```

For a value that is also needed in the class body (a `header` line, say), use `helper` instead of `private`; see [Helper Methods](helpers.md#the-helper-dsl-method).

---

## Variables Asgard Sets

Three of asgard's built-ins start tasks as new processes: the [watcher](watch.md), [background jobs](jobs.md) and [schedules](schedule.md). Each hands its process a specific environment, and a few `ASGARD_*` variables that tell the task why it is running.

### Tasks Run by the Watcher

A task the watcher triggers does **not** inherit the shell the watcher was started from. It gets:

| Layer | Contents |
|---|---|
| A fixed base | `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG`, every `LC_*`, `TMPDIR`, `SSH_AUTH_SOCK`, and the Ruby setup the watcher started under: `GEM_HOME`, `GEM_PATH`, `RUBYOPT`, `RUBYLIB`, every `BUNDLE_*` and `BUNDLER_*`. All captured when `asgard watcher start` ran |
| The declaration's `env:` | `watch :docs, paths: "docs", env: { BUILD_ENV: "dev" }` adds `BUILD_ENV=dev` |
| `.envrc` | Loaded in the task's own process through `direnv exec` when direnv is on `PATH` (see [`.envrc` and direnv](#envrc-and-direnv)) |
| `.env` | Only if your `.loki` calls `dotenv`, as it would for any run |
| The trigger | `ASGARD_WATCH`, the entry name; `ASGARD_WATCH_ROOT`, the project root; and the changed paths, below |

The changed paths arrive in three variables, one path per line, relative to the project root:

| Variable | Contents |
|---|---|
| `ASGARD_MODIFIED` | Files whose contents changed |
| `ASGARD_ADDED` | Files that appeared |
| `ASGARD_REMOVED` | Files that disappeared |
| `ASGARD_CHANGES_FILE` | Set instead of the three above when the lists are too large for the environment (over 128 KB, as a branch switch under a `**` watch can produce). It names a JSON file holding the same three lists |

You do not read these yourself. The `changes` method does, from whichever form they came in, and returns `.modified`, `.added`, `.removed` and `.all`; every list is empty when you run the task by hand. See [Watched Files](watch.md#reading-the-changes).

`asgard watcher preview` prints the exact command and environment each entry would run, so there is never any guessing about what a triggered task sees.

### Background Jobs

A job started with `sh "...", background: true` inherits the full environment of the task that started it, plus:

| Variable | Contents |
|---|---|
| `ASGARD_JOB` | The job's name (`doc_server-1`, `api`) |
| `ASGARD_JOB_STATUS` | The file the job's exit status is written to when it ends |
| `PYTHONUNBUFFERED` | Set to `1` unless you set it yourself. Python fully buffers stdout when it is a file, so without this a `print` loop would show nothing in the job's log until the process exits |

### Scheduled Tasks

A job installed by `asgard schedule install` runs under launchd or systemd, far from any shell of yours. It gets:

| Layer | Contents |
|---|---|
| `PATH` | The `PATH` that was current when you ran `install`. Change your `PATH` and re-run `install` to update it |
| The declaration's `env:` | `schedule :sync, every: 3600, env: { "SYNC_TARGET" => "s3://bucket" }`. The values are written into the job file, which only your user can read |
| `.envrc` | Loaded at run time through `direnv exec` when direnv is on `PATH` |
| `.env` | Only if your `.loki` calls `dotenv` |

Nothing else. In particular, variables you exported in `.zshrc` or `.bashrc` are not there, and neither is Homebrew's `PATH` on a Mac unless it was in `PATH` at install time. `asgard schedule preview` shows the job files, environment included, before you install them.

---

## Variables Asgard Reads

| Variable | Effect |
|---|---|
| `ASGARD_TRACE` | When set, a task file that fails to load prints the full Ruby backtrace instead of asgard's one-line summary. See [Help & Diagnostics](diagnostics.md#load-errors) |
| `ASGARD_LOG_MAX` | Bytes the watcher's log may reach before it is rotated to `watcher.log.1`. Default 10 MB |
| `XDG_STATE_HOME` | Where per-project state lives (watcher and job records, logs). Default `~/.local/state`; asgard uses `<XDG_STATE_HOME>/asgard/` |
| `XDG_CONFIG_HOME` | On Linux, where systemd user units are written. Default `~/.config` |
| `COLUMNS` | The width the `list` tables wrap to when output is not a terminal (piped to a file or `less`). Default 120 |
| `NO_COLOR` | When set, the `list` tables print without colour |

See [Files & Directories](files.md) for the paths these produce.

---

## `.envrc` and direnv

If the project root has a `.envrc`, asgard's watcher and schedules wrap each task in `direnv exec <root>`. The task's own process then loads `.envrc` the way your shell does when you `cd` into the project: API keys and other secrets reach the task at run time and are **never copied** into a launchd plist, a systemd unit or a watcher record. A rotated key takes effect on the next run with nothing to reinstall.

For that to work, `direnv` has to be on `PATH` when you run `asgard schedule install` or `asgard watcher start`. When it is not, each prints a warning and goes on without it:

```
schedule: .envrc found but direnv is not on PATH; its variables will not be loaded
watcher: .envrc found but direnv is not on PATH; its variables will not be loaded
```

A task you run by hand from a direnv-enabled shell already has `.envrc` loaded, so nothing changes there.

---

## `PATH` Is Not the Same Everywhere

The `PATH` in your terminal is built by your shell's startup files. A task that runs under launchd, systemd or the watcher never runs those files. The practical consequences:

- **A tool on your terminal's `PATH` may be missing in a scheduled run.** Homebrew's `/opt/homebrew/bin` is the usual example on a Mac. Schedules capture `PATH` at install time, so run `install` from a shell that has what the task needs. The watcher captures `PATH` at `start`.
- **The same name can be a different program.** `bash` in a Homebrew terminal is 5.x; under launchd it is the 3.2 build in `/bin`. A script that uses bash 4 syntax passes by hand and fails on a schedule.

Pin the executables that matter in the `shells` registry, so every run uses the same one:

```ruby
class Tasks
  shell :bash, "/opt/homebrew/bin/bash"
end
```

See [Shell Commands](shell.md#pinning-a-path).
