# Scheduled Tasks

Asgard can run any task on a schedule. You declare schedules in the project's own `.loki`, and `asgard schedule install` hands them to the platform's own scheduler: **launchd** on macOS, **systemd user timers** on Linux. Both schedulers run a calendar job that was missed while the machine slept as soon as it wakes.

Scheduling is built into the gem, so there is nothing to import or require.

---

## Declaring Schedules

Call `schedule` at class level inside `Tasks`:

```ruby
# .loki
class Tasks
  desc "daily_summary", "Summarize the day's work"
  def daily_summary = sh "bin/summary"

  schedule :daily_summary, at: "17:30", on: :weekdays
  schedule :weekly_report, at: "16:00", on: :friday
  schedule :sync,          every: 3600                 # seconds
  schedule :backup,        at: %w[02:00 14:00]         # on: defaults to :daily

  # The task's own options go in options:, split the way a shell would
  # (quotes respected).
  schedule :report, options: "--format md -v",  at: "08:00", on: :weekdays
  schedule :report, options: "--period week",   at: "16:00", on: :friday
  schedule :notify, options: "--msg 'backup done'", every: 86_400, as: "notify_daily"
end
```

A declaration needs exactly one of `at:` or `every:`.

| Keyword | Meaning |
|---------|---------|
| `at:` | `"HH:MM"` (24-hour), or an Array of times |
| `on:` | `:daily` (default), `:weekdays`, `:weekends`, a day (`:friday`), or an Array of days |
| `every:` | Interval in seconds, or anything that responds to `in_seconds` (an ActiveSupport `Duration`) |
| `options:` | The task's own arguments, as a String (split shell-style) or an Array of words |
| `env:` | `{ "KEY" => "value" }`: literal environment variables added to the job |
| `as:` | The entry's name (letters, digits, `_ . -`) |

### Entry Names

Every entry has a name, and the subcommands below take it as `NAME`. The name defaults to the task name. When the entry has `options:`, the default is a slug of the task plus its options (`:report, options: "--format md -v"` becomes `report-format-md-v`), so one task can be scheduled several times with different flags. `as:` overrides the default. Declaring two *different* entries with the same name raises an error.

### Durations

Asgard doesn't depend on ActiveSupport. If you want `every: 3.minutes`, require it yourself at the top of your `.loki`:

```ruby
require "active_support/core_ext/integer/time"

class Tasks
  schedule :sync, every: 15.minutes
end
```

---

## Managing Schedules

`schedule` is also a command with subcommands. They work the same way on both platforms:

```bash
asgard schedule preview        # print the job files install would write
asgard schedule install        # load declared entries; drop entries no longer declared
asgard schedule list           # this project's entries, state, last exit (--all: every project's)
asgard schedule stop NAME      # stop one entry (stays stopped across reboots and installs)
asgard schedule start NAME     # start a stopped entry, or install just this one
asgard schedule trigger NAME   # run an installed entry now, under the scheduler
asgard schedule log NAME [-f]  # print the entry's log (-f keeps following it)
asgard schedule remove         # unload and delete all of this project's entries
```

`stop`, `start`, `trigger` and `log` also accept an entry of another project, so
they work from any directory. Use the name shown by `list --all`; if two projects
have an entry with the same name, write it as `project/name` (this project's own
entry wins a bare name).

Re-run `asgard schedule install` after changing declarations or your `PATH`.

---

## How Jobs Run

Each entry runs `asgard <task> [options]` from the directory that holds `.loki`, so installing from any subdirectory gives the same result. The job gets the `PATH` that was current when you ran `install`, plus any `env:` variables.

If the project has a `.envrc`, the job runs under `direnv exec`, so API keys and other secrets load from `.envrc` at run time and are never copied into the job files. If `direnv` isn't on your `PATH`, `install` warns that `.envrc` will not be loaded.

Entries are scoped to the project (the name of the directory holding `.loki`), so `list`, `install` and `remove` only touch this project's jobs.

| | macOS (launchd) | Linux (systemd) |
|---|---|---|
| Job files | `~/Library/LaunchAgents/com.madbomber.asgard.<project>.<name>.plist` | `~/.config/systemd/user/asgard.<project>.<name>.{service,timer}` |
| Logs | `~/Library/Logs/asgard/` | `~/.local/state/asgard/` (honors `XDG_STATE_HOME`) |
| Stop | `launchctl disable` | `systemctl --user disable --now` |
| Caveats | runs only while you're logged in | runs only while you're logged in unless `loginctl enable-linger`; needs systemd 240+ |

Other platforms aren't supported. The `schedule` subcommands there exit with an error.

---

## Name Collisions

The built-in command is registered as `_schedule` and mapped to `schedule`, following Asgard's `_` convention for gem-owned tasks. If your `.loki` defines its own `schedule` task, `asgard schedule` still dispatches to the built-in command.
