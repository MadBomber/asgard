# Watched Files

Any task can run whenever files change. You say which files in the project's `.loki` with a `watch` line, and `asgard watcher start` runs one background process for the project that listens for changes and runs the matching tasks. Each run is a normal `asgard <task>`, started from the project root, and the task can ask what changed through `changes`.

Watching is built in. There is nothing to install or require beyond asgard itself.

---

## The Shortest Example

```ruby
# .loki
class Tasks
  desc "Run the test suite"
  def test = sh "bundle exec rake test"

  watch :test, paths: %w[lib test], only: /\.rb\z/
end
```

```bash
asgard watcher start
```

```
started watcher for api-9f3a1c2b (pid 12345); log: /Users/you/.local/state/asgard/watch/api-9f3a1c2b/watcher.log
```

Now edit a Ruby file under `lib/` or `test/` and look at the log:

```bash
echo "# tweak" >> lib/api.rb
asgard watcher log
```

```
2026-10-24 09:12:01 trigger test task=test lib/api.rb
2026-10-24 09:12:01 spawn test task=test pid=12351 lib/api.rb
bundle exec rake test
Run options: --seed 4211
...
2026-10-24 09:12:04 exit test task=test pid=12351 status=0 seconds=3.10
```

The watcher keeps running after you close the terminal. `asgard watcher stop` ends it.

<figure markdown>
--8<-- "docs/assets/images/watcher-flow.svg"
<figcaption>Saved files reach the watcher, which queues one run per task and starts each run as its own <code>asgard</code> process. Every task's output lands in <code>watcher.log</code>.</figcaption>
</figure>

---

## Declaring Watches

`watch` goes at class level inside `Tasks`. Each line names a task and the paths it cares about.

```ruby
class Tasks
  watch :lint,    paths: "lib/**/*.rb"
  watch :test,    paths: %w[lib test], only: /\.rb\z/, ignore: %r{\Afixtures/}
  watch :docs,    paths: "docs", env: { BUILD_ENV: "dev" }
  watch :reindex, paths: "data/**/*.json", events: %i[added removed], debounce: 1
  watch :gems,    paths: "Gemfile.lock"
  watch :lint,    paths: "bin/**/*", as: "lint-bin"
end
```

| Keyword | Meaning |
|---------|---------|
| `paths:` | A directory, a file or a glob, relative to the project root, or an Array of them |
| `only:` | A Regexp, or an Array of them, that a changed path must match (matched against the path relative to the watched directory) |
| `ignore:` | A Regexp, or an Array of them, that silences a path; added to the [default ignores](#default-ignores) |
| `events:` | Which kinds of change count: `:all` (the default), `:changed`, `:added`, `:removed`, or an Array of them; `:modified` is accepted as another name for `:changed` |
| `debounce:` | Seconds to wait after the last change before the task runs (default `0.5`) |
| `env:` | `{ KEY: "value" }`: environment variables added to the task's process |
| `as:` | The entry's name (see [Entry Names](#entry-names)) |

### Paths

A path is one of three things, judged in the project root:

| You write | What is watched |
|---|---|
| `"docs"` (an existing directory) | Everything beneath it, at any depth |
| `"Gemfile.lock"` (a file, or a name with an extension) | Just that file; it may not exist yet |
| `"lib/**/*.rb"` (a glob) | The directory before the first wildcard, keeping only paths that match |

Globs follow shell rules: `**` spans directories, `*` and `?` stay within one path segment, and `{a,b}` is an alternative:

```ruby
watch :assets, paths: "app/assets/**/*.{js,css}"
watch :notes,  paths: "notes/*.md"            # only the top level of notes/
```

Paths must be relative. An absolute path, or no path at all, is rejected when the `.loki` loads: `watch :lint paths are relative to the project root (got "/tmp/x")`.

### Mixing Directories and Patterns

A bare directory cannot share a declaration with a pattern or a file. The filter a pattern creates would apply to the directory as well, and silently drop most of what you meant to watch, so asgard refuses the combination:

```
asgard: /proj/.loki:4: watch :build mixes a bare directory with patterns or files, which would filter the directory too; declare them separately or write the directory as dir/**/* (ArgumentError)
```

Either fix works:

```ruby
watch :build, paths: %w[src/**/* config/*.yml]     # the directory as a glob
# or
watch :build, paths: "src"
watch :build, paths: "config/*.yml", as: "build-config"
```

### Narrowing with only:

`only:` adds a filter on top of the paths. A path must match one of the patterns from `paths:` **and** one of the `only:` expressions. The filter is applied to every directory the declaration watches, so with `paths: %w[lib/**/*.rb docs/**/*.md]` a `.md` file under `lib/` also matches; use separate declarations when that matters.

```ruby
watch :test, paths: %w[lib test], only: /\.rb\z/
watch :docs, paths: "docs", only: [/\.md\z/, /\.yml\z/]
```

`only:` and `ignore:` take Regexps, nothing else: `watch :docs only: expects a Regexp or an Array of them (got "*.md")`.

### Default Ignores

Every watch ignores `.git/`, `coverage/`, `pkg/`, `tmp/`, `log/` and `node_modules/` at any depth, so a task that writes its output inside the project never retriggers itself. `ignore:` adds to that list:

```ruby
watch :docs, paths: "docs", ignore: %r{\Adrafts/}
```

### Events

By default any change counts. `events:` restricts the kinds:

```ruby
watch :reindex, paths: "data/**/*.json", events: %i[added removed]   # not on edits
watch :compile, paths: "src", events: :changed                       # edits only
```

The kinds are `:changed`, `:added` and `:removed`; `:modified` means `:changed`. Anything else is rejected: `watch :compile events: unknown :edited; use :changed, :added, :removed or :all`.

### Debounce

Saving a file often produces several events in quick succession, and a tool that rewrites many files produces a burst. `debounce:` is how long the watcher waits after the last event before it runs the task, so the whole burst lands in one run. The default is half a second; raise it for tasks that should see a complete batch:

```ruby
watch :reindex, paths: "data/**/*.json", events: %i[added removed], debounce: 1
```

### Environment

`env:` adds variables to the task's process. The task reads them as usual, with `env(:build_env)` or `ENV["BUILD_ENV"]`:

```ruby
watch :docs, paths: "docs", env: { BUILD_ENV: "dev" }
```

### Entry Names

Every declaration is an **entry** with a name, shown by `list` and in every log line. The name defaults to the task name. To watch one task from two declarations, give the second an `as:` name:

```ruby
watch :lint, paths: "lib/**/*.rb"
watch :lint, paths: "bin/**/*", as: "lint-bin"
```

Two different declarations with the same name are an error when the `.loki` loads: `watch: "lint" is already declared; give one a distinct as: name`. Names may contain letters, digits, `_`, `.` and `-`.

A declaration that names a task the project does not define is caught when the watcher starts: `watcher: no such task(s): lintt`.

---

## Reading the Changes

Inside a task, `changes` returns what triggered it:

```ruby
changes.modified   # => ["lib/api.rb"]           paths relative to the project root
changes.added      # => []
changes.removed    # => []
changes.all        # => every path once, in that order
changes.empty?     # => true when the task was run by hand
```

Every list is empty when the task is run from the command line, so one task body serves both. A lint task that lints only what changed, and everything when nothing is known to have changed:

```ruby
class Tasks
  desc "Lint the Ruby files that changed, or all of them"
  def lint
    files = changes.modified + changes.added
    files = Dir["lib/**/*.rb"] if files.empty?
    sh "bundle exec rubocop #{files.shelljoin}"
  end

  watch :lint, paths: "lib/**/*.rb"
end
```

```bash
asgard lint              # by hand: lints every file under lib/
echo >> lib/api.rb       # from the watcher: lints lib/api.rb only
```

Behind `changes` are three environment variables the watcher sets for the task, `ASGARD_MODIFIED`, `ASGARD_ADDED` and `ASGARD_REMOVED`, one path per line. A shell script run with `sh` can read them directly. See [Environment Variables](environment.md).

---

## Managing the Watcher

`watcher` is also a command with subcommands:

```bash
asgard watcher start        # start the watcher for this project in the background
asgard watcher stop         # stop it; a task already running finishes first
asgard watcher list         # this project's watches, daemon state, each entry's last run
asgard watcher list --all   # every project's
asgard watcher preview      # the command and environment each entry would run
asgard watcher log          # print the watcher's log
asgard watcher log -f       # keep following it
asgard watcher run          # watch in the foreground (what start runs detached)
```

### start

`start` launches the watcher as a background process for this project and returns at once:

```bash
asgard watcher start
```

```
started watcher for api-9f3a1c2b (pid 12345); log: /Users/you/.local/state/asgard/watch/api-9f3a1c2b/watcher.log
```

There is one watcher per project. A second `start` is refused while the first runs: `watcher is already running for api-9f3a1c2b (pid 12345); `asgard watcher stop` first.` A pidfile left behind by a crash or a reboot does not count as running; `start` replaces it.

`start` refuses when there are no declarations, when a declaration names an unknown task, or when `asgard` is not on your `PATH`.

### stop

`stop` asks the watcher to finish. It stops listening, drops triggers that have not started, waits for any task that is already running, and then exits. While it waits it names what it is waiting for, once a second:

```bash
asgard watcher stop
```

```
watcher: waiting for test (pid 12351)
watcher: waiting for test (pid 12351)
stopped watcher for api-9f3a1c2b
```

`stop` never signals a running task. A task that hangs keeps `stop` waiting; kill the task and `stop` completes. With no watcher running: `watcher is not running for api-9f3a1c2b.`

### list

`list` shows this project's declarations, whether the watcher is running, and each entry's last run:

```bash
asgard watcher list
```

```
┌──────────┬────────────────┬─────────────────────────────────┬─────────┬─────────────────────────────────┐
│ NAME     │ TASK           │ WATCHES                         │ DAEMON  │ LAST RUN                        │
├──────────┼────────────────┼─────────────────────────────────┼─────────┼─────────────────────────────────┤
│ lint     │ asgard lint    │ lib/**/*.rb                     │ running │ 0 (0.4s, 2026-10-24 09:12:04)   │
│ test     │ asgard test    │ lib test                        │ running │ running (pid 12360)             │
│ docs     │ asgard docs    │ docs                            │ running │ 1 (2.1s, 2026-10-24 09:10:40)   │
│ reindex  │ asgard reindex │ data/**/*.json [added, removed] │ running │ did not finish (pid 12302)      │
│ lint-bin │ asgard lint    │ bin/**/*                        │ running │ never                           │
└──────────┴────────────────┴─────────────────────────────────┴─────────┴─────────────────────────────────┘

Logs: /Users/you/.local/state/asgard/watch  (asgard watcher log)
```

| LAST RUN | Meaning |
|---|---|
| `never` | The entry has not triggered since records began |
| `running (pid N)` | Its task is running now |
| `did not finish (pid N)` | The task's process is gone but no exit was recorded (a crash, a `kill -9`) |
| `0 (0.4s, 2026-10-24 09:12:04)` | The exit status, how long it took, and when it finished |

WATCHES lists the declared paths and, when `events:` restricts the kinds, those kinds in brackets. DAEMON is `running` or `stopped` for the whole project.

With no declarations:

```
No watches declared for api-9f3a1c2b. Add `watch :task, paths: "lib"` inside class Tasks in /Users/you/work/api/.loki.
Use `asgard watcher list --all` to see every project's watches.
```

`list --all` (`-a`) shows every project that has ever started a watcher, each under a `Project: slug (/path)` title, with `[root missing]` after a project whose directory no longer exists. Other projects' rows come from the declarations recorded when their watcher was started. Run from a directory with no `.loki` above it, `list` shows every project without `--all`.

### preview

`preview` prints, for each entry, the exact command the watcher would run and the complete environment the task would see, without running anything. It is the first thing to look at when a task behaves differently under the watcher than at the prompt.

```bash
asgard watcher preview
```

```
# lint: /opt/homebrew/bin/direnv exec /Users/you/work/api /Users/you/.gem/bin/asgard lint  (lib/**/*.rb)
ASGARD_ADDED=
ASGARD_MODIFIED=
ASGARD_REMOVED=
ASGARD_WATCH=lint
ASGARD_WATCH_ROOT=/Users/you/work/api
HOME=/Users/you
LANG=en_US.UTF-8
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
SHELL=/bin/zsh
USER=you

# docs: /opt/homebrew/bin/direnv exec /Users/you/work/api /Users/you/.gem/bin/asgard docs  (docs)
ASGARD_ADDED=
...
BUILD_ENV=dev
...
```

### log

The watcher writes one log for the project: a line for every trigger, spawn and exit, with each task's own output in between. `log` prints it; `-f` follows it:

```bash
asgard watcher log
asgard watcher log -f
```

Before the first `start` there is no log: `api-9f3a1c2b has no watcher log yet (/Users/you/.local/state/asgard/watch/api-9f3a1c2b/watcher.log); it is created on the first start.`

### run

`run` is the watcher in the foreground: the same process `start` launches, attached to your terminal instead of detached. It runs until you press Ctrl-C or send it TERM, then shuts down the way `stop` does and prints `watcher: stopped`. Use it to see the watcher's own messages as they happen, or as the process a service manager would supervise.

```bash
asgard watcher run
```

---

## How Tasks Run

Every trigger starts `asgard <task>` as a separate process from the project root. The watcher uses the very same `asgard` executable that started it, by absolute path, so a different version installed elsewhere on `PATH` is never picked up by accident.

**Different tasks run at the same time.** A save that matches `lint` and `docs` starts both at once.

**The same task never overlaps itself.** A trigger that arrives while its task is still running waits for it. Several triggers that arrive during one run merge: their changed paths are combined and the task runs once more when the current run ends, with every path from the merged triggers in `changes`. Save three times during a long test run and one more run follows, not three. The log says so:

```
2026-10-24 09:12:01 trigger test task=test lib/api.rb
2026-10-24 09:12:01 spawn test task=test pid=12351 lib/api.rb
2026-10-24 09:12:02 trigger test task=test lib/client.rb (queued behind pid 12351)
2026-10-24 09:12:03 trigger test task=test test/api_test.rb (queued behind pid 12351)
2026-10-24 09:12:04 exit test task=test pid=12351 status=0 seconds=3.10
2026-10-24 09:12:04 spawn test task=test pid=12377 lib/client.rb test/api_test.rb
2026-10-24 09:12:07 exit test task=test pid=12377 status=0 seconds=3.02
```

Each `trigger` line names the entry and the changed paths. Each `spawn` and `exit` line carries the task's pid, so the lines of tasks running side by side can be told apart; a task's own output sits between its `spawn` and its `exit`.

**Two declarations for the same task** (`lint` and `lint-bin` above) share one queue, so they never overlap either; a change that matches both runs the task twice, back to back.

**A task's `depends_on` runs inside its own process**, as it does from the command line. The watcher does not know about dependencies and does not collapse them across entries.

**A task that starts a [background job](jobs.md)** leaves it running after the task exits, and `asgard jobs` in the project directory shows it.

### The Environment a Task Sees

The task does not inherit the shell the watcher was started from. It sees the same environment whether the watcher came from an interactive terminal or from a service, which is what makes `preview` trustworthy.

| Layer | Contents |
|---|---|
| Base | `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG`, `LC_*`, `TMPDIR`, `SSH_AUTH_SOCK`, and the Ruby setup variables `GEM_HOME`, `GEM_PATH`, `RUBYOPT`, `RUBYLIB`, `BUNDLE_*`, captured when the watcher started |
| Declared | The entry's `env:`; the project's `.envrc` through `direnv exec` when direnv is on `PATH`; a `.env` through the `.loki`'s own `dotenv` call |
| Trigger | `ASGARD_WATCH` (the entry name), `ASGARD_WATCH_ROOT` (the project root), and the changed paths in `ASGARD_MODIFIED`, `ASGARD_ADDED` and `ASGARD_REMOVED`, one per line, relative to the root |

Nothing else from the daemon reaches the task. A change list too large for the environment (a branch switch under a `**` watch can change thousands of files) is written to a file instead, named by `ASGARD_CHANGES_FILE`; `changes` reads it the same way.

### Editing .loki While the Watcher Runs

The watcher watches its own task files too: every `.loki` the project loaded, and any new `.loki` that appears in the project root. Save one and the watcher restarts itself with the new declarations once any running task has finished; the log ends one run with `watcher: reloading` and the next begins. You never need to `stop` and `start` after changing a `watch` line.

If the edited files do not load (a syntax error, a typo), the watcher keeps the declarations it already has and says so in the log:

```
watcher: the task files do not load; keeping the running declarations
```

Fix the file and save again.

---

## Files and Logs

The watcher keeps everything outside the repository, under `~/.local/state/asgard/watch/<slug>/` (or `$XDG_STATE_HOME/asgard/watch/<slug>/`), where `<slug>` is the project directory's name plus a short hash of its full path, `api-9f3a1c2b`, the same slug [scheduled tasks](schedule.md#the-project-slug) and [background jobs](jobs.md) use:

| File | Contents |
|---|---|
| `watcher.pid` | The daemon's pid while it runs |
| `watcher.lock` | Held by the running daemon, so two cannot start |
| `watcher.log` | One line per trigger, spawn and exit, plus every task's output |
| `watcher.log.1` | The previous log, once `watcher.log` passed 10 MB (set `ASGARD_LOG_MAX` in bytes to change the limit) |
| `declarations.json` | The declarations recorded at `start`, which `list --all` reads for other projects |
| `entries/<name>.json` | Each entry's last run |
| `changes/` | Change lists too large for the environment, one file per trigger |
| `root` | The project directory, so `list --all` can find every project |

The directory is readable by you alone, since task output can hold secrets.

---

## A Worked Example

The asgard repository ships a small project under `examples/watcher_examples/` with four declarations and one placeholder file in each watched directory. Its `.loki`:

```ruby
class Tasks
  # A glob: watches lib/ and keeps the paths that match, like a shell would.
  watch :lint, paths: "lib/**/*.rb"

  # A directory with filters. only: narrows to Markdown; ignore: silences
  # the drafts folder; env: adds a variable the task can read with env().
  watch :docs, paths: "docs", only: /\.md\z/, ignore: %r{\Adrafts/}, env: { BUILD_ENV: "demo" }

  # events: picks which kinds of change count. Editing a data file does
  # nothing; creating or deleting one triggers a reindex. debounce: waits
  # a full second after the last event, so a batch of files lands at once.
  watch :reindex, paths: "data/**/*.json", events: %i[added removed], debounce: 1

  # The same task watched from a second declaration needs its own entry
  # name. Both entries share one queue, so lint never overlaps itself.
  watch :lint, paths: "bin/**/*", as: "lint-bin"

  desc "lint", "Report the Ruby files that changed"
  def lint
    files = changes.modified + changes.added
    return puts "lint: nothing changed (run by hand), so linting everything under lib/" if files.empty?

    files.each { |file| puts "lint: #{file} (#{File.foreach(file).count} lines) triggered by #{env(:asgard_watch, 'nothing')}" }
  end

  desc "docs", "Rebuild the documentation"
  def docs
    puts "docs: building for #{env(:build_env, 'development')}; changed: #{changes.all.join(', ')}"
  end

  desc "reindex", "Rebuild the data index"
  def reindex
    puts "reindex: #{changes.added.size} added, #{changes.removed.size} removed; #{Dir['data/**/*.json'].size} data file(s) now"
  end
end
```

From that directory:

```bash
asgard watcher start
echo '# a change' >> lib/greeter.rb         # lint runs, with the path in changes.modified
echo 'more' >> docs/index.md               # docs runs; BUILD_ENV=demo comes from env:
echo 'more' >> docs/drafts/ideas.md        # nothing: drafts/ is ignored
echo '{}' > data/new.json                  # reindex runs: a file was added
echo '{"edited": true}' > data/new.json    # nothing: events: is added and removed only
rm data/new.json                           # reindex runs again: a file was removed
asgard watcher log
```

```
2026-10-18 23:40:01 trigger lint task=lint lib/greeter.rb
2026-10-18 23:40:01 spawn lint task=lint pid=12351 lib/greeter.rb
lint: lib/greeter.rb (7 lines) triggered by lint
2026-10-18 23:40:02 exit lint task=lint pid=12351 status=0 seconds=0.41
2026-10-18 23:40:05 trigger docs task=docs docs/index.md
2026-10-18 23:40:05 spawn docs task=docs pid=12360 docs/index.md
docs: building for demo; changed: docs/index.md
2026-10-18 23:40:06 exit docs task=docs pid=12360 status=0 seconds=0.40
2026-10-18 23:40:09 trigger reindex task=reindex data/new.json
2026-10-18 23:40:09 spawn reindex task=reindex pid=12371 data/new.json
reindex: 1 added, 0 removed; 2 data file(s) now
2026-10-18 23:40:10 exit reindex task=reindex pid=12371 status=0 seconds=0.40
2026-10-18 23:40:13 trigger reindex task=reindex data/new.json
2026-10-18 23:40:13 spawn reindex task=reindex pid=12384 data/new.json
reindex: 0 added, 1 removed; 1 data file(s) now
2026-10-18 23:40:14 exit reindex task=reindex pid=12384 status=0 seconds=0.40
```

```bash
asgard watcher list
```

```
┌──────────┬────────────────┬──────────────────────────────────┬─────────┬───────────────────────────────┐
│ NAME     │ TASK           │ WATCHES                          │ DAEMON  │ LAST RUN                      │
├──────────┼────────────────┼──────────────────────────────────┼─────────┼───────────────────────────────┤
│ lint     │ asgard lint    │ lib/**/*.rb                      │ running │ 0 (0.4s, 2026-10-18 23:40:02) │
│ docs     │ asgard docs    │ docs                             │ running │ 0 (0.4s, 2026-10-18 23:40:06) │
│ reindex  │ asgard reindex │ data/**/*.json [added, removed]  │ running │ 0 (0.4s, 2026-10-18 23:40:14) │
│ lint-bin │ asgard lint    │ bin/**/*                         │ running │ never                         │
└──────────┴────────────────┴──────────────────────────────────┴─────────┴───────────────────────────────┘

Logs: /Users/you/.local/state/asgard/watch  (asgard watcher log)
```

```bash
asgard watcher stop
```

Every task also runs by hand, when `changes` is empty: `asgard lint` prints `lint: nothing changed (run by hand), so linting everything under lib/`.

!!! tip "Running the example from a checkout"
    The watcher runs its daemon and every task as separate `asgard` processes. If you are running asgard from a git checkout rather than an installed gem, install the checkout first (`asgard install` from the repository root), or an older gem on the machine may be the one the spawned processes run.

---

## Requirements

File events come from the [listen](https://github.com/guard/listen) gem: native change notifications on macOS and Linux, polling elsewhere. The gem also installs a small native extension, so `gem install asgard` needs a C++17 compiler on the machine.

Running the watcher as a launchd or systemd service is not built in yet. `asgard watcher run` is the foreground process such a service would keep alive.

---

## Name Collisions

The built-in command is registered under a reserved name and mapped to `watcher`. If your `.loki` defines its own task called `watcher`, `asgard watcher` still runs the built-in; name your task something else. (`run` is a name Thor uses internally and cannot be a task of yours at all, which is why the foreground command is `asgard watcher run` and not a task.)
