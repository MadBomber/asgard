# Upgrading to 0.6.0

Version 0.6.0 changes how asgard names a project on disk. Every scheduled
task and every watcher installed by an earlier version is filed under the
old name, and asgard 0.6.0 does not migrate them. If you use `schedule`
or `watch`, follow the steps on this page: stop everything under the old
version, upgrade, then start everything again.

`sh` and `shebang` changed too, and two of those changes can break a
`.loki`: the `exec:` keyword is gone, and every `sh` script now runs under
`bash`, which must be on `PATH`. Both are covered at the end of this page,
starting at [`sh` and `shebang`: `exec:` removed](#sh-and-shebang-exec-removed).
The other changes in the release are listed in the [Changelog](changelog.md).

---

## What Changed

Each project's scheduled jobs and watcher state are kept outside the
repository, under a name derived from the project. Before 0.6.0 that name
was the basename of the directory holding `.loki`, slugified: a project at
`~/work/api` was simply `api`.

| | Before 0.6.0 | From 0.6.0 |
|---|---|---|
| Project slug | `api` | `api-9f3a1c2b` |
| launchd label | `com.madbomber.asgard.api.<name>` | `com.madbomber.asgard.api-9f3a1c2b.<name>` |
| systemd units | `asgard.api.<name>.{service,timer}` | `asgard.api-9f3a1c2b.<name>.{service,timer}` |
| Watcher state | `~/.local/state/asgard/watch/api/` | `~/.local/state/asgard/watch/api-9f3a1c2b/` |

The suffix is the CRC32 of the project's full real path, written as eight
hex digits. It is stable for as long as the project stays where it is, and
it is the same whether you reach the project through a symlink or not.

---

## Why It Was Necessary

A directory name is not unique on a machine. Two checkouts called `api`,
a repository and its `examples/` directory alongside another repository's
`examples/`, a fork next to its upstream: any of these gave two projects
the same slug, and the slug was the only thing that told them apart.

The consequences were silent:

- **`asgard schedule install` in one project removed the other's jobs.**
  Install prunes every installed entry under the project's slug that the
  current `.loki` no longer declares. With a shared slug, the other
  project's entries looked like entries of this project that had been
  removed from `.loki`, so they were uninstalled.
- **The two watchers fought over one state directory.** Both wrote their
  root into the same `root` file, both used the same pidfile, so starting
  the second watcher was refused because "the watcher is already running",
  and `watcher list` showed one project's entries under the other's name.

Hashing the full path into the slug makes every project's name unique
without making it unreadable: the basename still comes first, and
`asgard schedule list --all` and `asgard watcher list --all` show the
full path next to each slug.

---

## Before You Upgrade

Do this with the **old** version still installed, so its commands find the
entries under their old names.

**1. Find every project with schedules or watches.** Both commands work
from any directory:

```bash
asgard schedule list --all
asgard watcher list --all
```

Each group is titled `Project: <slug> (<path>)`. The path is where to go
next.

**2. In each of those projects, remove the schedules and stop the
watcher:**

```bash
cd /path/to/project
asgard schedule remove      # unloads and deletes every job of this project
asgard watcher stop         # a task already running finishes first
```

`schedule remove` prints one `removed <name>` line per entry. `watcher
stop` waits for any running task, then prints `stopped watcher for
<slug>`.

**3. Check that nothing is left:**

```bash
asgard schedule list --all   # No scheduled tasks installed
asgard watcher list --all    # every project shows DAEMON stopped
```

!!! note
    A watcher that shows as stopped may still own a state directory under
    `~/.local/state/asgard/watch/<old slug>/`. It holds only the log and
    the last-run records and is harmless, but you can delete it once the
    watcher is stopped if you want a clean slate.

---

## Upgrade

```bash
gem update asgard
asgard --version     # 0.6.0
```

---

## After You Upgrade

In each project, install the schedules and start the watcher again. The
declarations in `.loki` are unchanged; only the name they are filed under
is new.

```bash
cd /path/to/project
asgard schedule install
asgard watcher start
```

Confirm the new slugs:

```bash
asgard schedule list --all
asgard watcher list --all
```

Every project title now ends in a hash, for example
`Project: api-9f3a1c2b (/Users/you/work/api)`.

---

## If You Already Upgraded

Entries installed by the old version are still there and still run. The
new version sees them as belonging to another project, because their slug
has no hash, so they appear in `schedule list --all` and `watcher list
--all` under the old name while your project's own entries, once
reinstalled, appear under the new one.

**Scheduled tasks.** A leftover entry can be stopped by its old slug:

```bash
asgard schedule stop api/nightly      # the old slug was the bare basename
```

Stopping disables the job but leaves its files. To remove them, delete the
job by hand:

=== "macOS (launchd)"

    ```bash
    launchctl bootout gui/$(id -u)/com.madbomber.asgard.api.nightly
    rm ~/Library/LaunchAgents/com.madbomber.asgard.api.nightly.plist
    ```

=== "Linux (systemd)"

    ```bash
    systemctl --user disable --now asgard.api.nightly.timer
    rm ~/.config/systemd/user/asgard.api.nightly.{service,timer}
    systemctl --user daemon-reload
    ```

**Watchers.** A leftover daemon keeps running under the old slug. Its
pidfile names it:

```bash
kill $(cat ~/.local/state/asgard/watch/api/watcher.pid)
rm -r ~/.local/state/asgard/watch/api
```

The daemon handles TERM the same way `watcher stop` does: it stops
listening, lets a running task finish, and exits.

Then install and start under the new version as described above.

---

## Related Changes in 0.6.0

Two smaller changes came with the slug and are worth knowing:

- In a `project/name` argument to `schedule stop`, `start`, `trigger` or
  `log`, the project may be the whole slug or just the directory name
  when that is enough to pick one project out: `asgard schedule stop
  api/nightly` reaches `api-9f3a1c2b/nightly`.
- `schedule list --all` and `watcher list --all` mark a project whose
  directory no longer exists with `[root missing]`. Its jobs were left
  behind by a move or a delete, and the hash will not match the project
  at its new location, so remove them the same way as the leftovers above
  and reinstall from the new location.

---

## `sh` and `shebang`: `exec:` removed

`sh` and `shebang` no longer take an `exec:` keyword. `sh` is `shebang`
with the default shell, so this is one change, not two. A `.loki` that
still passes it fails on the first call:

```
ArgumentError: unknown keyword: :exec
```

**What to do:** delete the keyword. The task keeps working the same way.

```ruby
# before
def doc_server = sh "mkdocs serve", exec: true

# from 0.6.0
def doc_server = sh "mkdocs serve"
```

**Why it was removed.** `exec: true` promised to replace the asgard
process with the command, so that nothing idle sat in memory beside a dev
server and a signal sent to the pid reached the command directly. Since
0.6.0 every script runs as a file under its shell, and a shell does not
hand its pid to the last command of a script file. With `exec: true` the
pid was bash, the command was its child, and a `kill` of that pid stopped
bash and left the command running on its own. The keyword no longer did
what the documentation said.

Without it, the shell is the unit of work: when the script finishes the
shell exits, asgard exits with its status, and Ctrl-C reaches asgard, the
shell and the command together because they share the terminal's process
group. That is the behaviour `exec: true` was meant to give, and it is now
the only behaviour.

---

## `sh` and `shebang`: every script runs under bash

Before 0.6.0 a one-line `sh "..."` went through Ruby's `system`, which
hands a single string to `/bin/sh`, while a multi-line script went through
`bash`. The same `sh` call therefore ran under two different shells
depending on line count, and bash syntax passed or failed with it. From
0.6.0 `sh` is `shebang :bash`: one line or many is written to a tempfile
and run by the `:bash` entry of the `shells` registry. Three things follow.

### `bash` must be on `PATH`

The seeded `:bash` entry is the bare word `bash`, found on `PATH` at run
time. A machine or container with only `/bin/sh` fails on the first `sh`:

```
asgard: shell :bash not found: bash ...
```

and asgard exits 127. Every desktop system, and any image that installs
bash, is unaffected.

**What to do**, if you cannot install bash:

```ruby
class Tasks
  default_shell :sh           # sh and a nameless shebang run /bin/sh's `sh`
end
```

or keep `:bash` as the name and point it somewhere else:

```ruby
class Tasks
  shell :bash, "/bin/sh"      # every sh and shebang :bash runs this instead
end
```

The first form is right when your scripts are POSIX sh already. The
second is a quick way to get a container running; scripts that use bash
features will then fail under `/bin/sh` the way they did before 0.6.0.

### One-liners now run under bash, not `/bin/sh`

On macOS `/bin/sh` is bash in POSIX mode, so one-liners behave almost
exactly as before. On Debian and Ubuntu `/bin/sh` is dash, so a one-line
script that ran under dash now runs under bash. Bash accepts nearly
everything dash does, so this mostly adds features rather than removing
them, but a few builtins differ:

| | dash (`/bin/sh` on Debian) | bash |
|---|---|---|
| `echo "a\tb"` | interprets `\t` | prints `\t` literally (use `printf`) |
| `[ a == b ]` | error: `unexpected operator` | works |

**What to do:** nothing, unless a one-liner depended on dash-only
behaviour. A script that needs `/bin/sh` exactly can ask for it by name:
`shebang :sh, "..."`. The `:sh` entry is seeded and runs `sh` from `PATH`.

### `$0` is a tempfile path

A script that printed `$0`, typically in a usage message, used to show
`bash` or the command itself. It now shows the tempfile the script was
written to, such as
`/var/folders/.../T/asgard_20261024-80545-bmbloc.sh`. The file is deleted
when the script finishes.

**What to do:** print a name you choose instead of `$0`. Nothing else
reads it.

### Also changed, not breaking

- `sh` and `shebang` return `true`; they used to return `nil`.
- A command that ends on a signal exits 128 plus the signal number, as a
  shell would. It used to raise a `TypeError` from a nil exit status.
- A missing interpreter is named in the error message and exits 127
  instead of exiting 127 silently.
