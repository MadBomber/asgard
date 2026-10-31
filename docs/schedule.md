# Scheduled Tasks

Any task can run on a timer. You say when in the project's `.loki` with a `schedule` line, and `asgard schedule install` hands the entry to the scheduler your operating system already has: **launchd** on macOS, **systemd user timers** on Linux. From then on the task runs whether or not a terminal is open, and a run that was missed while the machine slept happens as soon as it wakes.

Scheduling is built in. There is nothing to install or require beyond asgard itself.

---

## The Shortest Example

```ruby
# .loki
class Tasks
  desc "Summarize the day's work"
  def daily_summary = sh "bin/summary"

  schedule :daily_summary, at: "17:30", on: :weekdays
end
```

```bash
asgard schedule install
```

```
installed daily_summary: asgard daily_summary (17:30 weekdays)
```

That is a working schedule. Every weekday at 17:30 the scheduler runs `asgard daily_summary` in the directory that holds `.loki`, and its output goes to a log you can read with `asgard schedule log daily_summary`.

<figure markdown>
--8<-- "docs/assets/images/schedule-flow.svg"
<figcaption>A declaration in <code>.loki</code> is installed into the platform scheduler, which runs the task in the project root and appends its output to a log.</figcaption>
</figure>

---

## Declaring Schedules

`schedule` goes at class level inside `Tasks`, next to the tasks it names. A declaration needs exactly one of `at:` (a time of day) or `every:` (an interval).

```ruby
class Tasks
  schedule :daily_summary, at: "17:30", on: :weekdays
  schedule :weekly_report, at: "16:00", on: :friday
  schedule :sync,          every: 3600                 # seconds
  schedule :backup,        at: %w[02:00 14:00]         # on: defaults to :daily
  schedule :heartbeat,     at: "09:00", on: %i[monday thursday]

  # The task's own command-line options go in options:
  schedule :report, options: "--format md -v",      at: "08:00", on: :weekdays
  schedule :report, options: "--period week",       at: "16:00", on: :friday
  schedule :notify, options: "--msg 'backup done'", every: 86_400, as: "notify_daily"
end
```

| Keyword | Meaning |
|---------|---------|
| `at:` | A time of day as `"HH:MM"` (24-hour clock), or an Array of them |
| `on:` | Which days `at:` applies to: `:daily` (the default), `:weekdays`, `:weekends`, one day such as `:friday`, or an Array of days |
| `every:` | An interval in seconds, or any object that answers `in_seconds` (an ActiveSupport Duration) |
| `options:` | The task's own arguments and flags, as one String split the way a shell would (quotes respected) or as an Array of words |
| `env:` | `{ "KEY" => "value" }`: environment variables added to the job |
| `as:` | The entry's name (see [Entry Names](#entry-names)) |

### Times and Days

`at:` takes one time or several. `on:` chooses the days; leave it out for every day.

```ruby
schedule :backup, at: "02:00"                          # every day at 02:00
schedule :backup, at: %w[02:00 14:00]                  # twice a day
schedule :standup, at: "09:25", on: :weekdays
schedule :cleanup, at: "23:00", on: :weekends
schedule :review,  at: "16:00", on: %i[tuesday thursday]
```

A time that is not `HH:MM`, an hour above 23, a minute above 59, an unknown day name, or an empty Array are all rejected when the `.loki` loads, with a message that names the problem:

```
asgard: /proj/.loki:9: at: expects "HH:MM" (got "5pm") (ArgumentError)
asgard: /proj/.loki:10: on: unknown day :funday (ArgumentError)
```

### Intervals

`every:` runs the task repeatedly, one interval after the scheduler starts it and one interval after each run. It takes a number of seconds:

```ruby
schedule :sync, every: 900        # every 15 minutes
schedule :poll, every: 60 * 60    # Ruby arithmetic is fine
```

Asgard does not depend on ActiveSupport, but it accepts anything that answers `in_seconds`, so `15.minutes` works once you require it yourself at the top of the `.loki`:

```ruby
require "active_support/core_ext/integer/time"

class Tasks
  schedule :sync, every: 15.minutes
end
```

An interval that is zero, negative or not a number is rejected: `schedule :sync every: must be a positive number of seconds or a Duration (3.minutes)`.

An interval entry runs on every day, so `on:` goes with `at:` only. Giving `every:` an `on:` is an error rather than a day filter that is quietly ignored: `schedule :sync on: only applies to at: times; every: runs on every day`.

### Options for the Task

The scheduler runs `asgard <task>` with nothing else unless you say otherwise. `options:` carries the task's own arguments and flags. A String is split the way a shell splits a command line, so quotes group words:

```ruby
schedule :report, options: "--format md --title 'Week End'", at: "16:00", on: :friday
schedule :report, options: %w[--format md --since 2026-01-01], at: "08:00"
```

Both forms run the task with each word passed as its own argument, so nothing is re-split or re-quoted on the way to the task. Newlines and other control characters are not allowed in `options:` or in `env:` values, because the job files are line-based.

### Environment Variables

`env:` adds literal variables to the job. Keys must be valid variable names (letters, digits and underscores, not starting with a digit).

```ruby
schedule :deploy_docs, at: "03:00", env: { "SITE_ENV" => "production", "VERBOSE" => "1" }
```

Secrets do not belong here, because `env:` values are written into the job file. Put them in a `.envrc` instead and let [direnv](#how-jobs-run) load them at run time. See [Environment Variables](environment.md) for what a scheduled task sees.

---

## Entry Names

Every declaration becomes an **entry** with a name, and every `asgard schedule` subcommand that acts on one entry takes that name as `NAME`.

| Declaration | Entry name |
|---|---|
| `schedule :daily_summary, at: "17:30"` | `daily_summary` |
| `schedule :report, options: "--format md -v", at: "08:00"` | `report-format-md-v` |
| `schedule :report, options: "--period week", at: "16:00"` | `report-period-week` |
| `schedule :report, options: "--period=week", at: "16:00"` | `report-period-week-` plus 8 hex digits |
| `schedule :notify, options: "--msg 'backup done'", every: 86_400, as: "notify_daily"` | `notify_daily` |

The name defaults to the task name. When the entry has `options:`, the default is a slug of the task plus its options, so one task can be scheduled several times with different flags and each run has its own entry, state and log.

The slug keeps only lowercase letters, digits and dashes, so on its own it could give two different commands the same name. When an option holds anything else (`--period=week`, a capital letter, a quoted `'Week End'`), or the slug would be longer than 64 characters, the name is shortened if needed and ends in a dash and 8 hex digits taken from the exact options. The same options always give the same digits. Plain slugs can still meet: `schedule :report, options: "--period week"` and `schedule :report, options: "period week"` are different commands that both slug to `report-period-week`. When two declarations in a `.loki` do that, both take the dash-and-digits form, whichever comes first. Run `asgard schedule preview` or `list` to see the name, or choose one with `as:`.

`as:` replaces the default with a name you choose; it may contain letters, digits, `_`, `.` and `-`.

Two different declarations that end up with the same name are an error when the `.loki` loads:

```
asgard: /proj/.loki:12: schedule: "report" is already declared; give one a distinct as: name (ArgumentError)
```

(Loading the same declaration twice, as happens when a file is imported from two places, is fine.)

### Task Names with Dashes and Subcommands

A task is always one word. A dash in it is taken as the underscore of the method name, so `schedule :"daily-summary"` schedules the `daily_summary` task. A subcommand's task cannot be named with a colon; schedule the subcommand itself and put the rest in `options:`:

```ruby
schedule :db, options: "migrate --dry-run", at: "02:00"   # runs: asgard db migrate --dry-run
```

Writing `schedule :"db:migrate"` is rejected with exactly that advice.

---

## Managing Schedules

`schedule` is also a command with subcommands. They work the same way on macOS and Linux.

```bash
asgard schedule preview        # print the job files install would write
asgard schedule install        # install declared entries; remove this project's undeclared ones
asgard schedule list           # this project's entries, their state and last exit
asgard schedule list --all     # every project's entries
asgard schedule log NAME       # print the entry's log
asgard schedule log NAME -f    # keep following it
asgard schedule trigger NAME   # run an installed entry now
asgard schedule stop NAME      # stop one entry; it stays stopped until started
asgard schedule start NAME     # start a stopped entry, or install just this one
asgard schedule remove [NAME]  # remove one entry, or all of this project's
asgard schedule prune          # remove every project's entries whose directory is gone
```

The rest of this section walks through each one with the `.loki` from the [declaration example](#declaring-schedules).

### preview

`preview` prints the job files that `install` would write, one block per entry, each headed by its path and summary. It does not install anything, so it is the place to check that the command, the working directory and the schedule are what you meant.

```bash
asgard schedule preview
```

=== "macOS (launchd)"

    ```
    # /Users/you/Library/LaunchAgents/com.madbomber.asgard.api-9f3a1c2b.report-period-week.plist: asgard report --period week (16:00 friday)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>com.madbomber.asgard.api-9f3a1c2b.report-period-week</string>
      <key>ProgramArguments</key>
      <array>
        <string>/opt/homebrew/bin/direnv</string>
        <string>exec</string>
        <string>/Users/you/work/api</string>
        <string>asgard</string>
        <string>report</string>
        <string>--period</string>
        <string>week</string>
      </array>
      <key>WorkingDirectory</key>
      <string>/Users/you/work/api</string>
      <key>EnvironmentVariables</key>
      <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
      </dict>
      <key>StandardOutPath</key>
      <string>/Users/you/Library/Logs/asgard/com.madbomber.asgard.api-9f3a1c2b.report-period-week.log</string>
      <key>StandardErrorPath</key>
      <string>/Users/you/Library/Logs/asgard/com.madbomber.asgard.api-9f3a1c2b.report-period-week.log</string>
      <key>StartCalendarInterval</key>
      <array>
        <dict>
          <key>Hour</key>
          <integer>16</integer>
          <key>Minute</key>
          <integer>0</integer>
          <key>Weekday</key>
          <integer>5</integer>
        </dict>
      </array>
    </dict>
    </plist>
    ```

=== "Linux (systemd)"

    ```
    # /home/you/.config/systemd/user/asgard.api-9f3a1c2b.report-period-week.service: asgard report --period week (16:00 friday)
    [Unit]
    Description=asgard report --period week (api-9f3a1c2b)

    [Service]
    Type=oneshot
    WorkingDirectory=/home/you/work/api
    Environment="PATH=/home/you/.local/bin:/usr/local/bin:/usr/bin:/bin"
    ExecStart="/usr/bin/direnv" "exec" "/home/you/work/api" "asgard" "report" "--period" "week"
    StandardOutput=append:/home/you/.local/state/asgard/asgard.api-9f3a1c2b.report-period-week.log
    StandardError=append:/home/you/.local/state/asgard/asgard.api-9f3a1c2b.report-period-week.log
    # /home/you/.config/systemd/user/asgard.api-9f3a1c2b.report-period-week.timer: asgard report --period week (16:00 friday)
    [Unit]
    Description=asgard report --period week (api-9f3a1c2b)

    [Timer]
    OnCalendar=Fri *-*-* 16:00:00
    Persistent=true
    AccuracySec=1s
    Unit=asgard.api-9f3a1c2b.report-period-week.service

    [Install]
    WantedBy=timers.target
    ```

The `direnv exec` wrapper appears only when the project has a `.envrc` and `direnv` is on your `PATH`; otherwise the arguments start with the absolute path of `asgard`.

### install

`install` writes the job files for every declared entry, loads them, and removes any entry of **this project** that is installed but no longer declared. It prints one line per entry:

```bash
asgard schedule install
```

```
installed daily_summary: asgard daily_summary (17:30 weekdays)
installed weekly_report: asgard weekly_report (16:00 friday)
installed sync: asgard sync (every 3600s)
installed backup: asgard backup (02:00, 14:00 daily)
installed report-format-md-v: asgard report --format md -v (08:00 weekdays)
installed report-period-week: asgard report --period week (16:00 friday)
installed notify_daily: asgard notify --msg 'backup done' (every 86400s)
```

An entry you stopped earlier is reinstalled but left stopped, and the line says so: `installed sync: ... [stopped; `asgard schedule start sync` to resume]`. An entry that was removed from `.loki` prints `removed NAME`.

`install` refuses to run when a declaration names a task the project does not define (`schedule: no such task(s): nightly`), when there are no declarations at all, or when `asgard` itself is not on your `PATH`. On Linux it ends with a note about lingering when your user timers would stop at logout (see [Platforms](#platforms)).

Run `install` again whenever you change a declaration, or whenever your `PATH` changes (a new Ruby, a new Homebrew prefix). The job keeps the `PATH` that was current at install time, nothing else.

### list

`list` shows this project's installed entries as a table with their live state and the exit status of their last run:

```bash
asgard schedule list
```

```
┌───────────────────────┬────────────────────────────────────┬──────────────────┬────────────┬───────────┐
│ NAME                  │ COMMAND                            │ SCHEDULE         │ STATE      │ LAST EXIT │
├───────────────────────┼────────────────────────────────────┼──────────────────┼────────────┼───────────┤
│ backup                │ asgard backup                      │ 02:00, 14:00 ... │ active     │ 0         │
│ daily_summary         │ asgard daily_summary               │ 17:30 weekdays   │ active     │ never run │
│ notify_daily          │ asgard notify --msg 'backup done'  │ every 86400s     │ stopped    │ -         │
│ report-format-md-v    │ asgard report --format md -v       │ 08:00 weekdays   │ running    │ 0         │
│ report-period-week    │ asgard report --period week        │ 16:00 friday     │ active     │ 1         │
│ sync                  │ asgard sync                        │ every 3600s      │ not loaded │ -         │
│ weekly_report         │ asgard weekly_report               │ 16:00 friday     │ active     │ 0         │
└───────────────────────┴────────────────────────────────────┴──────────────────┴────────────┴───────────┘

Logs: /Users/you/Library/Logs/asgard  (asgard schedule log NAME)
```

| STATE | Meaning |
|---|---|
| `active` | Installed and waiting for its next time |
| `running` | The task is running right now |
| `stopped` | Stopped with `asgard schedule stop`; it will not fire until started |
| `not loaded` | The job files exist but the scheduler does not have the entry loaded (a reboot that did not reload it, a hand edit); `asgard schedule install` fixes it |

LAST EXIT is the exit status of the last run (`0` is success), `never run` for an active entry that has not fired yet, or `-` for an entry that is stopped or not loaded. A run ended by a signal shows the signal: `signal 15 (Terminated)` on macOS, `signal 15 (SIGTERM)` on Linux. A non-zero status or a signal is shown in red on a terminal; set `NO_COLOR` to turn colour off. Long COMMAND and SCHEDULE cells wrap to the terminal width, and a run of hourly times collapses to `10:00-17:00 hourly weekdays`.

An entry that is installed but no longer in `.loki` shows `no longer declared` in the SCHEDULE column until the next `install` removes it.

With nothing installed:

```
No scheduled tasks installed for api-9f3a1c2b (launchd).
Use `asgard schedule list --all` to see all currently scheduled tasks.
```

### log

Each entry appends the stdout and stderr of every run to its own log file. `log NAME` prints it; `-f` keeps printing as new output arrives, like `tail -f`:

```bash
asgard schedule log daily_summary
asgard schedule log daily_summary -f
```

An entry that has never run has no log yet: `daily_summary has no log yet (/Users/you/Library/Logs/asgard/...log); it is created on the first run.`

### trigger

`trigger NAME` runs an installed entry right now, under the scheduler and with the scheduler's environment, which makes it the honest way to test a schedule: a task that works at your prompt but fails under `trigger` has a `PATH` or environment problem, not a code problem.

```bash
asgard schedule trigger daily_summary
```

```
triggered daily_summary; output goes to /Users/you/Library/Logs/asgard/com.madbomber.asgard.api-9f3a1c2b.daily_summary.log
```

A stopped entry is refused: `daily_summary is stopped; `asgard schedule start daily_summary` first.`

### stop and start

`stop NAME` stops one entry. The stop is remembered: the entry stays stopped across reboots and across later `install` runs, until you `start` it.

```bash
asgard schedule stop sync
# stopped sync
asgard schedule start sync
# started sync
```

`start NAME` does two things. For an entry that is declared in this project's `.loki` it refreshes the job files from the current declaration and installs just that one entry, whether or not it was installed before; so `start` is also the way to install a single new entry without touching the others. For an entry that is installed but no longer declared, or that belongs to another project, it starts the installed job as it is and says so on stderr: `schedule: sync is no longer declared; starting its installed job as-is`.

### remove

`remove NAME` unloads and deletes one entry's job files and forgets any stop. `remove` with no name does that for every entry of this project:

```bash
asgard schedule remove sync
# removed sync
asgard schedule remove
# removed backup
# removed daily_summary
# ...
```

The log files are left in place.

If the scheduler refuses to unload an entry, `remove` stops with an error and leaves its job files where they are, so the entry still shows in `list` and you can try again. `prune`, and `install` removing an undeclared entry, behave the same way.

### prune

A project that was moved or deleted leaves its entries behind, and they keep firing in a directory that is not there. `prune` removes every such entry, from every project on the machine. `--dry-run` (`-n`) only lists them:

```bash
asgard schedule prune --dry-run
# would remove api-9f3a1c2b/daily_summary
asgard schedule prune
# removed api-9f3a1c2b/daily_summary
```

With nothing to do it prints `Nothing to prune: every installed entry's project directory exists.`

### Every Project at Once

`list --all` (`-a`) shows every project's entries, grouped under a title that names the project and its directory. Other projects' `.loki` files are not loaded; their columns are read back from the installed job files.

```bash
asgard schedule list --all
```

```
Project: api-9f3a1c2b (/Users/you/work/api)
┌───────────────┬──────────────────────┬────────────────┬────────┬───────────┐
│ NAME          │ COMMAND              │ SCHEDULE       │ STATE  │ LAST EXIT │
├───────────────┼──────────────────────┼────────────────┼────────┼───────────┤
│ daily_summary │ asgard daily_summary │ 17:30 weekdays │ active │ 0         │
└───────────────┴──────────────────────┴────────────────┴────────┴───────────┘

Project: blog-13ab77e0 (/Users/you/old/blog) [root missing]
┌─────────┬────────────────┬─────────────┬────────┬───────────┐
│ NAME    │ COMMAND        │ SCHEDULE    │ STATE  │ LAST EXIT │
├─────────┼────────────────┼─────────────┼────────┼───────────┤
│ publish │ asgard publish │ 06:00 daily │ active │ 127       │
└─────────┴────────────────┴─────────────┴────────┴───────────┘

Logs: /Users/you/Library/Logs/asgard  (asgard schedule log NAME)
```

`[root missing]` marks a project whose directory no longer exists; `prune` removes its entries. Run from a directory with no `.loki` above it, `list` shows every project without needing `--all`.

### Reaching Another Project's Entry

`stop`, `start`, `trigger`, `log` and `remove` accept an entry of any project, so they work from any directory. Name it as `project/name`, where `project` is the slug shown by `list --all`, or just the directory name when that is enough to pick one project out:

```bash
asgard schedule stop blog/publish            # the directory name is enough
asgard schedule stop blog-13ab77e0/publish   # the full slug always works
asgard schedule log api/daily_summary -f
```

A bare name is looked up in this project first, then in every other project. When two other projects share a name, asgard asks you to be specific: `publish is in several projects (blog-13ab77e0, blog-9c0f22d1); name one as project/publish.`

---

## How Jobs Run

Each entry runs `asgard <task> [options]` from the directory that holds `.loki`, so it does not matter which subdirectory you ran `install` from. The job's environment is small and fixed:

- `PATH` as it was when you ran `install`. A scheduler does not read your shell's startup files, so this is the only `PATH` the job has. Re-run `install` after changing it.
- The declaration's `env:` variables.
- If the project has a `.envrc`, the job is wrapped in `direnv exec`, so the variables in `.envrc` (API keys, credentials) are loaded at run time and never copied into the job files. If `direnv` is not on your `PATH`, `install` warns: `schedule: .envrc found but direnv is not on PATH; its variables will not be loaded`.
- Whatever the task's own `.loki` loads with `dotenv`, since that runs inside the task's process as usual.

The job's stdout and stderr are appended to its log file. Background jobs the task starts keep running after the task itself finishes, on both platforms.

A calendar entry (`at:`) that was due while the machine was asleep or off runs as soon as the machine is back; on macOS launchd does this on wake, and on Linux the timer is `Persistent`. An interval entry (`every:`) simply resumes its cadence.

### The Project Slug

Entries belong to a project, and the project is named by a **slug**: the name of the directory holding `.loki` plus a short hash of that directory's full path, such as `api-9f3a1c2b`. Two projects in directories with the same name therefore never share entries, and `install` in one can never remove the other's. The slug is stable as long as the project stays where it is; a moved project gets a new slug, and its old entries show up under `[root missing]` until you `prune` them and `install` again from the new location.

The slug appears in the job file names, the log file names and the `list --all` titles.

### Shells Under the Scheduler

The `PATH` a job sees is rarely the one your terminal has. On a Mac with Homebrew, `bash` at the terminal is 5.x from `/opt/homebrew/bin`, while under launchd it may be the 3.2 build in `/bin`. If a task's script needs a particular interpreter, pin it in the `.loki` so the same one runs everywhere:

```ruby
class Tasks
  shell :bash, "/opt/homebrew/bin/bash"
end
```

See [Shell Commands](shell.md#pinning-a-path).

---

## Platforms

| | macOS (launchd) | Linux (systemd) |
|---|---|---|
| Job files | `~/Library/LaunchAgents/com.madbomber.asgard.<slug>.<name>.plist` | `~/.config/systemd/user/asgard.<slug>.<name>.service` and `.timer` (honours `XDG_CONFIG_HOME`) |
| Logs | `~/Library/Logs/asgard/com.madbomber.asgard.<slug>.<name>.log` | `~/.local/state/asgard/asgard.<slug>.<name>.log` (honours `XDG_STATE_HOME`) |
| `stop` | `launchctl disable` plus unload; remembered by launchd | `systemctl --user disable --now` on the timer |
| Missed runs | Run on wake | `Persistent=true` on calendar timers |
| Runs while logged out? | No; user agents run only while you are logged in | Only after `loginctl enable-linger`; `install` prints a reminder when lingering is off |
| Requirements | | systemd 240 or later |

Any other platform is unsupported: every `asgard schedule` subcommand there exits with `asgard: <platform> is not supported (needs macOS launchd or Linux systemd)`.

Job files are written readable by you alone, since they can hold `env:` values. On macOS a plist is checked with `plutil` before it replaces the installed one. On both platforms `install` leaves an unchanged entry alone, so a reinstall never interrupts a run in progress or restarts an `every:` countdown.

---

## Troubleshooting

**The job never runs.** Check `asgard schedule list`. `stopped` means a `stop` is in effect: `start` it. `not loaded` means the scheduler lost the entry: `install` again. On macOS, user agents run only while you are logged in; on Linux, run `loginctl enable-linger` or the timers stop when you log out. `trigger NAME` runs the entry right now under the scheduler, which tells you whether the job itself works.

**`schedule: asgard is not on PATH`.** `install` needs to write the absolute path of `asgard` into the job. Make sure the directory holding the `asgard` executable (your Ruby's gem bin directory) is on `PATH` in the shell you run `install` from.

**`schedule: .envrc found but direnv is not on PATH; its variables will not be loaded`.** The project has a `.envrc`, but the job cannot load it without direnv. Install direnv and run `install` again, or move the variables the task needs into `env:`.

**The job fails with `command not found` after a Ruby or Homebrew upgrade.** The job still has the `PATH` from the day you installed it. Run `asgard schedule install` again to capture the current one.

**The task works at the prompt but fails under the scheduler.** The job's environment is only `PATH`, `env:` and `.envrc`; nothing from your shell's startup files reaches it. Run `asgard schedule trigger NAME` and read `asgard schedule log NAME` to see the actual error. See [Environment Variables](environment.md).

**`schedule: no such task(s): x`.** A declaration names a task that no loaded `.loki` defines. Check the spelling, and check that the file defining it is imported (see [Task Files](task-files.md)).

---

## Name Collisions

The built-in command is registered under a reserved name and mapped to `schedule`. If your `.loki` defines its own task called `schedule`, `asgard schedule` still runs the built-in; name your task something else.
