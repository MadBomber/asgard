# Watched Files

Asgard can run a task whenever files change. You declare what each task watches in the project's own `.loki`, and `asgard watcher start` runs a background process that listens for changes and runs the matching tasks, handing each one the list of changed files in a known, reproducible environment.

Watching is built into the gem, so there is nothing to import or require. File events come from the [listen](https://github.com/guard/listen) gem: native adapters on macOS and Linux, polling elsewhere.

---

## Declaring Watches

Call `watch` at class level inside `Tasks`:

```ruby
# .loki
class Tasks
  desc "lint", "Lint whatever changed"
  def lint
    files = changes.modified + changes.added
    sh "rubocop #{files.shelljoin}" unless files.empty?
  end

  watch :lint,    paths: "lib/**/*.rb"
  watch :test,    paths: %w[lib test], only: /\.rb\z/, ignore: %r{\Afixtures/}
  watch :docs,    paths: "docs", env: { BUILD_ENV: "dev" }
  watch :reindex, paths: "data/**/*.json", events: %i[added removed]
  watch :lint,    paths: "bin/**/*", as: "lint-bin"
end
```

| Keyword | Meaning |
|---------|---------|
| `paths:` | A directory, a file, or a glob relative to the project root, or an Array of them |
| `only:` | Regexp or Array of Regexps a changed path must match (relative to the watched directory) |
| `ignore:` | Regexp or Array of Regexps that silence a path, added to the defaults below |
| `events:` | Which kinds of change count: `:changed`, `:added`, `:removed`, or `:all` (default); `:modified` means `:changed` |
| `debounce:` | Seconds to wait after the last event before the task runs (default 0.5) |
| `env:` | `{ "KEY" => "value" }`: environment variables added to the task |
| `as:` | The entry's name (letters, digits, `_ . -`) |

### Entry Names

Every entry has a name, shown by `list` and in the log. It defaults to the task name. To watch one task from two declarations, give the second an `as:` name; declaring two *different* entries with the same name raises an error.

### Paths, Patterns and Filters

A glob such as `lib/**/*.rb` watches `lib` and keeps the paths that match the pattern, the way a shell would: `**` spans directories, `*` and `?` stay within one, `{a,b}` is an alternative. A plain file watches its directory and keeps just that name, so a file that does not exist yet can still be watched. A bare directory takes everything beneath it.

`only:` combines with the patterns: a path must match one of the patterns *and* one of the `only:` expressions. Several patterns in one declaration are alternatives, and because the filter applies to every directory the declaration watches, `%w[lib/**/*.rb docs/**/*.md]` also accepts a `.md` file under `lib`.

A bare directory cannot share a declaration with a pattern or a file, because the pattern would silently filter the directory too. Write the directory as `dir/**/*`, or declare it separately.

### Default Ignores

Every watch ignores `.git/`, `coverage/`, `pkg/`, `tmp/`, `log/` and `node_modules/` at any depth, plus listen's own defaults, so a task that writes its output inside the project never retriggers itself.

---

## Managing the Watcher

`watcher` is also a command with subcommands:

```bash
asgard watcher start        # start the watcher for this project in the background
asgard watcher stop         # stop it; a task already running finishes first
asgard watcher list         # this project's watches, daemon state, each entry's last run (--all: every project's)
asgard watcher preview      # the command and environment each watch would run
asgard watcher log [-f]     # print (or follow) the watcher's log
asgard watcher run          # watch in the foreground (what start runs detached)
```

The watcher watches its own `.loki` files too. Save one, and the running watcher restarts itself with the new declarations.

`stop` never signals a running task. It stops listening, drops triggers that have not started, waits for in-flight tasks to exit (naming them while it waits), then exits. A task that hangs keeps `stop` waiting; kill the task and `stop` completes.

---

## How Tasks Run

A trigger runs `asgard <task>` from the project root as a separate process, using the very `asgard` executable that started the watcher, by absolute path, so a different version installed elsewhere on `PATH` is never picked up. Different tasks run concurrently. The same task never overlaps itself: a trigger that arrives while its task is still running waits, and the log says `queued behind pid N`. Save three times during a long test run and three more runs follow, one at a time.

Two declarations for the same task that both match a file run that task twice, back to back. A task's own `depends_on` runs inside its process as usual; the watcher does not collapse dependencies across entries.

### The Environment

The task sees the same environment whether the watcher was started from an interactive shell or from a service. Nothing else leaks in from the daemon.

| Layer | Contents |
|---|---|
| Base | `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG`, `LC_*`, `TMPDIR`, `SSH_AUTH_SOCK`, captured when the watcher starts |
| Declared | The entry's `env:`; a project `.envrc` through `direnv exec` when direnv is on `PATH`; a `.env` through your `.loki`'s own `dotenv` call |
| Trigger | `ASGARD_WATCH` (the entry name), `ASGARD_WATCH_ROOT`, and the changed paths in `ASGARD_MODIFIED`, `ASGARD_ADDED` and `ASGARD_REMOVED`, one path per line, relative to the root |

### The `changes` Accessor

Inside a task, `changes` returns what triggered it:

```ruby
changes.modified   # => ["lib/asgard/base.rb"]
changes.added      # => []
changes.removed    # => []
changes.all        # => every path once, in that order
changes.empty?     # => true when the task was run by hand
```

Every list is empty when the task is run from the command line, so one task body serves both.

---

## Files and Logs

The watcher keeps its state outside the repository under `~/.local/state/asgard/watch/<project>/` (honors `XDG_STATE_HOME`): the pidfile, `watcher.log` with one line per trigger, spawn and exit plus every task's output, the declarations recorded at `start`, and one JSON record per entry with its last run. `asgard watcher list --all` reads those records for every project without loading any `.loki`.

Running the watcher as a launchd or systemd service is not yet built in; `asgard watcher run` is the foreground process a service would keep alive.

---

## Requirements

Watching needs Ruby 3.2 or later. The gem depends on `listen` and on `ractor_queue`, a native extension, so `gem install asgard` compiles it and needs a C++17 compiler on the machine.

## Name Collisions

The built-in command is registered as `_watcher` and mapped to `watcher`, following Asgard's `_` convention for gem-owned tasks. If your `.loki` defines its own `watcher` task, `asgard watcher` still dispatches to the built-in command.
