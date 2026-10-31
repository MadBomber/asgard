# Asgard

> [!INFO]
> See the [CHANGELOG](CHANGELOG.md) for the latest changes. The [examples directory](examples/) contains working `.loki` files demonstrating the full feature set.

> [!WARNING]
> Version 0.6.0 has breaking changes to scheduled tasks, watchers and `sh`. Read [Breaking Changes](https://madbomber.github.io/asgard/breaking-changes/) before you upgrade.

<br>
<table>
<tr>
<td width="40%" align="center" valign="top">
<img src="docs/assets/images/asgard.jpg" alt="Asgard"><br>
<em>"Loki writes the tricks. Asgard runs them."</em>
</td>
<td width="60%" valign="top">
<strong>Key Features</strong><br>

- <strong>Thor-Powered CLI</strong>: every Thor DSL feature available inside <code>.loki</code> task files<br>
- <strong>Task Dependencies</strong>: sequential, parallel, and mixed dependency graphs via <code>depends_on</code><br>
- <strong>Concurrent Execution</strong>: parallel task groups run in native Ruby threads<br>
- <strong>Subcommands</strong>: group related tasks under a named namespace<br>
- <strong>Variables</strong>: shared configuration via Ruby class variables (<code>@@name</code>), visible across all tasks and subcommands<br>
- <strong>`helper` DSL</strong>: define a method once, available in both class-level DSL calls (<code>header</code>) and inside task instance methods<br>
- <strong>Shell Helpers</strong>: <code>sh</code> (alias <code>shebang</code>) runs a command or heredoc under the default shell, or under any registered interpreter when you name one<br>
- <strong>Dotenv Support</strong>: load <code>.env</code> files into the environment with <code>dotenv</code><br>
- <strong>Auto-Discovery</strong>: <code>.loki</code> root marker searched from CWD upward through parent directories<br>
- <strong>Multi-File Tasks</strong>: split tasks across <code>*.loki</code> files, loaded via <code>import</code> from your <code>.loki</code><br>
- <strong>Scheduled Tasks</strong>: run any task periodically under launchd (macOS) or systemd timers (Linux) with <code>schedule</code> and <code>asgard schedule install</code><br>
- <strong>Watched Files</strong>: run any task when files change with <code>watch</code> and <code>asgard watcher start</code>; the task reads what changed through <code>changes</code><br>
- <strong>Background Jobs</strong>: <code>sh "mkdocs serve", background: true</code> starts a job that outlives asgard; <code>asgard jobs</code> lists, stops, restarts and cleans them<br>
- <strong>Built-in Flags</strong>: <code>--debug</code>, <code>--verbose</code>, <code>--version</code>, and <code>--doctor</code> built-in class options; header/footer DSL for static help text<br>
</td>
</tr>
</table>

<p>Asgard is a <a href="https://github.com/rails/thor">Thor</a>-based task runner for Ruby projects. Define tasks in <code>.loki</code> files, declare dependencies between them, and let Asgard handle ordering and concurrent execution. Anything Thor can do (subcommands, typed options, argument validation) is available inside a <code>.loki</code> file.</p>

## Installation

Asgard requires Ruby 4.0 or later. Scheduled tasks and the file watcher need macOS or Linux, background jobs need a POSIX system (`fork`, `setsid` and `/bin/sh`), and installing compiles one native extension, so a C++17 compiler must be available (Xcode's command-line tools or a distribution's `build-essential` package).

```bash
gem install asgard
```

Or add to your Gemfile:

```bash
bundle add asgard
```

---

## Tasks

Every `.loki` file defines tasks as methods inside `class Tasks`. The `Tasks` class is pre-defined by the gem; just reopen it and add methods.

### A task with no parameters

```ruby
class Tasks
  desc "Say hello"
  def hello = puts "Hello, World!"
end
```

```bash
asgard hello
```

### A task with a positional parameter

Declare positional parameters directly in the method signature. Document them in the `desc` usage string:

```ruby
class Tasks
  desc "hello NAME", "Say hello to NAME"
  def hello(name = "World") = puts "Hello, #{name}!"
end
```

```bash
asgard hello
asgard hello Alice
```

### A task with a formal argument declaration

Use `argument` for richer metadata: type checking, enums, and help text. **Warning: `argument` is a class-level declaration that applies to every task in the class**, not just the one below it. It is best suited for single-command CLIs or when every task genuinely shares the same positional input. In multi-task files, prefer method signature parameters instead.

```ruby
class Tasks
  argument :name,
           type:    :string,
           default: "World",
           desc:    "Name to greet"

  desc "hello NAME", "Say hello to NAME"
  def hello = puts "Hello, #{name}!"
end
```

### A task with named options

Use `method_option` (alias: `option`) for named flags. Access them inside the method via `options[:name]`:

```ruby
class Tasks
  desc "hello NAME", "Say hello to NAME"
  method_option :shout,  aliases: "-s", type: :boolean, desc: "Uppercase the output"
  method_option :count,  aliases: "-n", type: :numeric, default: 1, desc: "Repeat N times"
  def hello(name = "World")
    message = options[:shout] ? "HELLO, #{name.upcase}!" : "Hello, #{name}!"
    options[:count].times { puts message }
  end
end
```

```bash
asgard hello Alice --shout --count 3
```

### A task with an extended description

`long_desc` provides detailed help shown by `asgard help <task>`:

```ruby
class Tasks
  long_desc <<~DESC
    Says hello to NAME.
    Repeats the greeting COUNT times.
    Use --shout to uppercase the output.
  DESC
  desc "hello NAME", "Say hello to NAME"
  method_option :shout, aliases: "-s", type: :boolean, desc: "Uppercase the output"
  method_option :count, aliases: "-n", type: :numeric, default: 1, desc: "Repeat N times"
  def hello(name = "World")
    message = options[:shout] ? "HELLO, #{name.upcase}!" : "Hello, #{name}!"
    options[:count].times { puts message }
  end
end
```

---

## Dependencies

`depends_on` declares what must run before a task. Each dependency runs at most once per `asgard` invocation regardless of how many tasks declare it. Circular dependencies are caught at startup.

`desc` and `depends_on` are independent: either can come first, but both must appear before `def`.

### Sequential dependencies

Bare symbols run one after another in the order declared:

```ruby
class Tasks
  desc "Compile the project"
  def build = sh "rake build"

  depends_on :build
  desc "Run the test suite"
  def test = sh "rake test"

  depends_on :test
  desc "Publish the gem"
  def release = sh "bundle exec rake release"
end
```

```bash
asgard release   # build → test → release
```

### Parallel dependencies

Wrap symbols in an array to declare they can run concurrently. Asgard waits for all tasks in a parallel group to finish before moving to the next stage:

```ruby
class Tasks
  desc "Check code style"
  def lint = sh "bundle exec rubocop"

  desc "Run type checks"
  def typecheck = sh "bundle exec srb tc"

  # lint and typecheck run in parallel, test waits for both
  depends_on [:lint, :typecheck]
  desc "Run the test suite"
  def test = sh "bundle exec rake test"
end
```

```bash
asgard test   # lint ∥ typecheck → test
```

### Mixed sequential and parallel

Mix bare symbols (sequential) and arrays (parallel) in a single `depends_on` call. Execution proceeds stage by stage; each stage must complete before the next begins:

```ruby
class Tasks
  desc "Install dependencies"; def setup  = sh "bundle install"
  desc "Check code style";     def lint   = sh "bundle exec rubocop"
  desc "Compile assets";       def build  = sh "rake assets:precompile"
  desc "Run tests";            def test   = sh "bundle exec rake test"
  desc "Post to Slack";        def notify = sh "curl $SLACK_WEBHOOK -d '{\"text\":\"done\"}'"

  # setup first, then lint+build in parallel, then test, then notify
  depends_on :setup, [:lint, :build], :test, :notify
  desc "Full CI pipeline"
  def ci = puts "CI complete"
end
```

```
asgard ci executes:

  setup
    ↓
  lint ∥ build    (concurrent)
    ↓
  test
    ↓
  notify
    ↓
  ci
```

`depends_on` also accepts a `Proc`/lambda (or, equivalently, a block) instead of a fixed list, resolved once every `.loki` file has finished loading rather than immediately. This is useful when the list can't be known upfront, e.g. "every task whose name ends in `_check`," discovered across several files:

```ruby
depends_on -> { [all_commands.keys.grep(/_check\z/).map(&:to_sym)] }
def quality = puts "running every *_check task..."

depends_on { [all_commands.keys.grep(/_check\z/).map(&:to_sym)] }
def quality2 = puts "same, as a block..."

# do...end for a block spanning multiple statements; braces are for
# single-line blocks like the two above. The last expression is still what
# gets returned and validated.
depends_on do
  checks = all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)
  slow   = %i[c_check]

  [checks - slow]
end
def quality3 = puts "same, minus the slow checks, as a multi-line block..."
```

See [Dependencies](https://madbomber.github.io/asgard/dependencies/#dynamic-dependencies) for the full explanation.

---

## Variables

Shared configuration values are declared as Ruby class variables (`@@name`) at the top of the class body. Use `||=` so the first declaration wins when multiple `.loki` files reopen `Tasks`, and `.freeze` to prevent mutation:

```ruby
class Tasks
  @@app     ||= "myapp".freeze
  @@max_jobs ||= 4

  desc "Create a release tag"
  def tag = sh "git tag #{@@app}-#{version}"

  private

  def version = `git describe --tags`.strip
end
```

Class variables are visible in all task instance methods and in subcommand subclasses, unlike class instance variables (`@name`), which are not accessible inside instance methods.

---

## Helper methods

Private methods are callable from any task in the same class but are never registered as commands: they won't appear in `--help` output and can't be invoked from the CLI.

```ruby
class Tasks
  desc "Compile and package"
  def build
    compile("src")
    package(version)
  end

  desc "Build and publish"
  def release
    build
    sh "gem push pkg/myapp-#{version}.gem"
  end

  private

  def compile(dir)
    sh "gcc -O2 -o bin/myapp #{dir}/*.c"
  end

  def package(ver)
    sh "tar czf pkg/myapp-#{ver}.tar.gz bin/"
  end

  def version = File.read("VERSION").strip
end
```

### The `helper` DSL method

Some values need to be available in both class context (e.g. inside `header`) and inside task instance methods. `helper` defines the method once in both contexts:

```ruby
class Tasks
  @@project ||= "myapp".freeze

  helper(:version) {
    File.read("lib/myapp/version.rb").match(/VERSION\s*=\s*"([^"]+)"/)[1].freeze
  }

  header "#{@@project} v#{version}"   # class context

  desc "Show the current version"
  def show_version
    puts version                        # instance context
  end
end
```

Without `helper`, achieving this requires two separate definitions:

```ruby
def self.version = File.read(...).match(...)[1].freeze
no_commands { private def version = self.class.version }
```

`helper` accepts positional arguments, keyword arguments, and blocks: any signature valid in a Ruby method definition:

```ruby
helper(:tag) { |name, ver, prefix: "v"| "#{prefix}#{name}-#{ver}" }
```

Helpers can also be shared across multiple `.loki` files by extracting them into a plain Ruby file and loading it explicitly:

```ruby
# shared/helpers.rb
module BuildHelpers
  private

  def compile(dir)
    sh "gcc -O2 -o bin/myapp #{dir}/*.c"
  end
end

# .loki
require_relative "shared/helpers"

class Tasks
  include BuildHelpers

  desc "Compile the project"
  def build = compile("src")
end
```

---

## Help header and footer

Add static text above and below the command list in `asgard help` output:

```ruby
class Tasks
  header "my-project: build & release tasks"
  footer "See https://example.com/docs for details"
end
```

Multiple calls accumulate. `header` appends each line (top to bottom); `footer` prepends each line (bottom to top), so content from a later-loaded `.loki` file sits closer to the commands:

```ruby
# .loki
class Tasks
  header "my-project"
  footer "Maintainer: you@example.com"
end

import "*.loki"

# deploy.loki
class Tasks
  header "  deploy targets: staging, production"
  footer "See runbook at wiki/deploy"
end
```

```
asgard v0.6.0 The Mighty Thor and Loki working for you

my-project

  deploy targets: staging, production

Commands:
  ...

Options:
  ...

See runbook at wiki/deploy

Maintainer: you@example.com


Documentation ... https://madbomber.github.io/asgard
Github Repo ..... https://github.com/MadBomber/asgard
```

Header and footer text is only shown for the general `asgard help` page, not for `asgard help <command>`.

---

## Options shared across all tasks

`class_option` defines an option available to every task in the class:

```ruby
class Tasks
  class_option :dry_run, aliases: "-n", type: :boolean, desc: "Print commands without running"

  desc "deploy ENV", "Deploy to the given environment"
  def deploy(env = "staging")
    if options[:dry_run]
      puts "Would deploy to #{env}"
    else
      sh "cap #{env} deploy"
    end
  end
end
```

---

## Shell helpers

`sh` writes a script body to a tempfile and runs it with a registered interpreter; given a script alone it uses the `default_shell` (bash), for one line or a heredoc. `shebang` is the same method under a longer name, which many authors reserve for scripts in another language. Both return `true` and exit with the command's status code on failure.

```ruby
class Tasks
  desc "Bootstrap the development environment"
  def setup
    sh <<~SHELL
      brew install redis postgresql
      brew services start redis
      bundle install
      rails db:setup
    SHELL
  end

  desc "Run Python data analysis"
  def analyze
    shebang :python3, <<~PYTHON
      import json
      data = json.load(open("results.json"))
      print(f"Total: {sum(data.values())}")
    PYTHON
  end

  desc "Build frontend assets with esbuild"
  def bundle_assets
    shebang :node, <<~JS
      const esbuild = require("esbuild")
      esbuild.buildSync({ entryPoints: ["src/app.js"], bundle: true, outfile: "dist/app.js" })
    JS
  end
end
```

Registered shells: `:bash`, `:sh`, `:python3`, `:python`, `:node`, `:ruby`, `:perl`. Any other symbol runs as itself from `PATH` with a `.tmp` extension, except zsh, fish, csh and tcsh, which get `.sh`, `.fish` and `.csh`. Register your own, with a pinned path or options in front of the script, with `shell`:

```ruby
class Tasks
  shell :bash,   "/opt/homebrew/bin/bash"      # what sh and shebang :bash run
  shell :strict, "bash -eu -o pipefail"
  shell :uv,     "uv run --script", ext: ".py"
  default_shell :strict                         # what sh and a nameless shebang run
end
```

The name may be left out: `shell "/usr/local/bin/bash -c -w"` registers `:bash`, named after the executable, with the options as its `args`. `default_shell` registers and selects in one line the same way: `default_shell "/usr/local/bin/bash -c -w"`, or `default_shell :strict, "bash", args: "-eu -o pipefail"`. A bare `default_shell :bash` only selects and leaves a pinned entry alone.

Pass `silent: true` to both `sh` and `shebang` to suppress the script echo:

```ruby
def build   = sh "rake build", silent: true
def analyze = shebang :python3, <<~PY, silent: true
  import json
  print(json.load(open("data.json")))
PY
```

---

## Environment variables

`dotenv` loads a `.env` file into the environment before tasks run. Use the `env` Kernel method to read environment variables inside task bodies. It accepts a symbol or string and upcases the key automatically:

```ruby
class Tasks
  dotenv              # loads .env
  dotenv ".env.local" # or a specific file

  desc "Start the server"
  def start
    sh "puma -p #{env(:port, '3000')} -e #{env(:rack_env, 'development')}"
  end

  desc "Deploy the app"
  def deploy
    sh "cap #{env(:deploy_target)} deploy"  # raises KeyError if DEPLOY_TARGET is unset
  end
end
```

| Call | Behaviour |
|------|-----------|
| `env(:port, "3000")` | Returns `"3000"` when `PORT` is unset |
| `env(:api_key)` | Raises `KeyError` when `API_KEY` is missing |
| `env("DATABASE_URL")` | String name works too; always upcased |

---

## Abbreviated command matching

Every task is a Thor command, so you don't have to type the full name: Thor resolves any unambiguous prefix automatically, with no extra code:

```ruby
class Tasks
  desc "Compile the project"
  def build = sh "rake build"

  desc "Deploy to production"
  def deploy = sh "cap production deploy"

  desc "Deploy to staging"
  def deploy_staging = sh "cap staging deploy"
end
```

```bash
asgard b        # same as: asgard build   (only task starting with "b")
asgard depl     # Ambiguous command depl matches [deploy, deploy_staging]
asgard deploy   # runs deploy; an exact match always wins, even over a shorter ambiguous prefix
```

This is Thor's own dispatch behavior, not an Asgard feature; it applies to every task in every `.loki` file automatically. When a prefix matches more than one task, Thor lists the candidates instead of guessing; type enough of the name to disambiguate, or use `map` (below) to pin a short name that stays stable even if a later-added task would otherwise make it ambiguous.

---

## Command aliases

`map` creates alternative names for a task:

```ruby
class Tasks
  map "-v"  => "version"
  map "--v" => "version"
  map "t"   => "test"

  desc "Print the version"
  def version = puts Asgard::VERSION
end
```

---

## Subcommands

Group related tasks under a common name using Thor's `subcommand` method. Define a subcommand class that inherits from `Tasks`, then register it with a name and description.

```ruby
class DeployCommands < Tasks
  desc "Deploy to staging"
  def staging = sh "cap staging deploy"

  desc "Deploy to production"
  def production = sh "cap production deploy"
end

class Tasks
  desc "deploy SUBCOMMAND", "Deploy the application"
  subcommand "deploy", DeployCommands
end
```

```bash
asgard deploy           # shows deploy subcommand help
asgard deploy staging
asgard deploy production
```

Subcommand tasks have all the same access to `sh`, `shebang`, `depends_on`, and the built-in `--debug`/`--verbose` class options as normal tasks. `@@` class variables declared on `Tasks` are also visible in subcommand subclasses.

`depends_on` only works within a subcommand group exactly as it does at the top level:

```ruby
class DBCommands < Tasks
  desc "Run pending migrations"
  def migrate = sh "rails db:migrate"

  desc "Load seed data"
  def seed = sh "rails db:seed"

  depends_on :migrate, :seed
  desc "Migrate then seed"
  def reset = puts "Done."
end

class Tasks
  desc "db SUBCOMMAND", "Manage the database"
  subcommand "db", DBCommands
end
```

```bash
asgard db reset   # migrate → seed → reset
```

Each subcommand group can have its own `desc`, `long_desc`, `option`, `class_option`, and `map` declarations, all scoped to that group.

See [`examples/server_subcommands.loki`](examples/server_subcommands.loki) and [`examples/db_subcommands.loki`](examples/db_subcommands.loki) for full working examples.

---

## Scheduled tasks

Any task can run on a schedule under the platform's own scheduler:
**launchd** on macOS, **systemd user timers** on Linux. Declare schedules at
class level in `.loki`:

```ruby
class Tasks
  schedule :daily_summary, at: "17:30", on: :weekdays
  schedule :backup,        at: %w[02:00 14:00]          # on: defaults to :daily
  schedule :sync,          every: 3600                  # seconds
  schedule :report, options: "--period week", at: "16:00", on: :friday
end
```

Then manage them with the built-in `schedule` command:

```bash
asgard schedule preview        # job files install would write
asgard schedule install        # load declared entries; drop undeclared ones
asgard schedule list           # this project's entries, state, last exit (--all: every project's)
asgard schedule stop NAME      # stop one entry (persists across reboots and installs)
asgard schedule start NAME     # start a stopped entry, or install just this one
asgard schedule trigger NAME   # run an installed entry now
asgard schedule log NAME [-f]  # print (or follow) the entry's log
asgard schedule remove [NAME]  # remove one entry, or all of this project's
asgard schedule prune [-n]     # remove every project's entries whose directory is gone (-n: list only)
```

`stop`, `start`, `trigger`, `log` and `remove` also take an entry of another project
(`list --all` shows them); write `project/name` when two projects share a name.

Jobs run `asgard <task> [options]` from the directory holding `.loki`, with
the `PATH` captured at install time; a project `.envrc` is loaded at run time
through `direnv exec`. See [Scheduled Tasks](https://madbomber.github.io/asgard/schedule/)
for every keyword, entry naming, and file locations.

## Watched files

Any task can run when files change. Declare what each task watches at class
level in `.loki`:

```ruby
class Tasks
  watch :lint, paths: "lib/**/*.rb"
  watch :test, paths: %w[lib test], only: /\.rb\z/
  watch :reindex, paths: "data/**/*.json", events: %i[added removed]

  desc "lint", "Lint whatever changed"
  def lint
    files = changes.modified + changes.added   # empty when run by hand
    sh "rubocop #{files.shelljoin}" unless files.empty?
  end
end
```

Then manage the watcher with the built-in `watcher` command:

```bash
asgard watcher start        # watch this project in the background
asgard watcher stop         # stop it; a task already running finishes first
asgard watcher stop --force # stop it and end any running task
asgard watcher list         # watches, daemon state, each entry's last run (--all: every project's)
asgard watcher preview      # the command and environment each watch would run
asgard watcher log [-f]     # print (or follow) the watcher's log
```

Each trigger runs `asgard <task>` from the project root with a fixed
environment plus the changed paths in `ASGARD_MODIFIED`, `ASGARD_ADDED` and
`ASGARD_REMOVED`. Different tasks run concurrently; the same task never
overlaps itself. Saving a `.loki` file restarts the watcher with the new
declarations. See [Watched Files](https://madbomber.github.io/asgard/watch/)
for every keyword, the environment, and file locations.

## Background jobs

A script runs in one of three modes. `sh "rake build"` is the foreground:
the task waits for it and a failure exits asgard. `sh "mkdocs serve",
background: true` starts a managed job: the task continues at once, the
job runs on in its own session with its output in a log, it is still
running when asgard exits, and `asgard jobs` manages it from then on. A
trailing `&` in the script is the third mode, detached: the shell exits,
asgard reports success and keeps no record, and the process is yours to
find and kill by hand.

```ruby
class Tasks
  desc "doc_server", "Serve the documentation"
  def doc_server = sh "mkdocs serve", background: true   # job doc_server-1

  desc "servers", "Bring up the development stack"
  def servers
    sh "docker compose up postgres", background: true    # servers-1
    sh "bin/rails server",            background: :api   # api
  end
end
```

```bash
asgard jobs list            # running, exited with a status, or gone (--all: every project's)
asgard jobs stop servers    # by job name, or by task and the tasks it depends on
asgard jobs log api -f      # print (or follow) one job's log
asgard jobs restart api     # stop it, then run its owning task again
asgard jobs clean           # forget every job that is no longer running
```

`stop` sends TERM to the job's whole process group and KILL after a
timeout. A job's pid is verified against its command line before anything
trusts it, so a pid reused after a reboot shows as `gone`, never as
running. See [Background Jobs](https://madbomber.github.io/asgard/jobs/)
for naming, the trampoline, and file locations.

## `method_option` types reference

| Type | CLI example | Ruby value |
|---|---|---|
| `:string` | `--branch main` | `"main"` |
| `:boolean` | `--force` / `--no-force` | `true` / `false` |
| `:numeric` | `--count 3` | `3` |
| `:array` | `--tags foo bar baz` | `["foo", "bar", "baz"]` |
| `:hash` | `--vars KEY:val FOO:bar` | `{"KEY" => "val", "FOO" => "bar"}` |

Common `method_option` keys: `aliases`, `type`, `default`, `required`, `desc`, `enum`, `banner`.

---

## Task files

Asgard searches the current directory and its ancestors for a `.loki` file. That file marks the project root. Additional `*.loki` files are loaded only when your `.loki` file explicitly calls `import`.

### Single file

```
myproject/
  .loki
```

### Multiple files

Split tasks across files; each reopens `class Tasks`:

```
myproject/
  .loki          ← entry point; calls import to load task files
  build.loki
  deploy.loki
  test.loki
```

The `.loki` entry file must call `import` to load the other task files. It also marks the project root for auto-discovery:

```ruby
# .loki
import "*.loki"
```

```ruby
# build.loki
class Tasks
  desc "Compile the project"
  def build = sh "rake build"
end
```

```ruby
# test.loki
class Tasks
  depends_on :build
  desc "Run the test suite"
  def test = sh "bundle exec rake test"
end
```

```ruby
# deploy.loki
class Tasks
  depends_on :test
  desc "Deploy to production"
  def deploy = sh "cap production deploy"
end
```

`.loki` is the only file asgard loads on its own, so in a single-file project it holds the tasks. In a multi-file project it needs at least the `import` calls that load the others, and may hold nothing else.

### Explicit loading

Load any Ruby or `.loki` file manually from `.loki`. Use `require_relative` for plain Ruby; use `import` for `.loki` files (it enforces the extension and is idempotent):

```ruby
# .loki
require_relative "shared/helpers"
import "ci.loki"

class Tasks
  # additional tasks
end
```

---

## Tips

- **Start from working files.** The task files at this repository's root (`.loki`, `quality.loki`, `gem_tasks.loki`, `git.loki`, `doc_tasks.loki`) are a real multi-file project: quality gates that return `:pass` or `:fail`, a background job, a subcommand group, a `helper` feeding the `header`, and a deliberate override for `--doctor`. Copy what fits.

- **More examples.** [MadBomber/dev](https://github.com/MadBomber/dev) holds shared `.loki` libraries used across many repos: gem, git, Rails quality, schedule, status report and iTerm tasks. The [examples directory](examples/) here has one small file per feature.

- **One setup for every project.** Put the tasks, shells and helpers you want everywhere in `~/.loki`, then start each project's `.loki` with `import "~/.loki"`. Outside any project the same file is found by the walk up the tree, so those tasks work in any directory.

- **Give busy tasks a short name with `map`.** `map "t" => "test"` stays stable when a later task would otherwise make the prefix `t` ambiguous. Thor's prefix matching is handy; an alias is dependable.

- **Make bare `asgard` do the common thing.** `default_task :test` (or `:quality`, as this repo does) saves typing on the task you run most.

- **Flags go after the task name.** `asgard build --verbose` runs the task; `asgard --verbose build` prints the help for `build`. Only `--version` and `--doctor` go first.

- **See the tasks by file with `asgard --doctor`.** It lists every `.loki` file that loaded and, under each, the tasks that file defines with their line numbers, plus which `.loki` won the walk up the tree, what every `import` loaded, tasks hidden because they lack a `desc`, and definitions silently replaced by a later one. It works even when the `.loki` will not load.

- **See the commands as a tree with `asgard tree`.** Every command with its description, each subcommand group expanded under its own heading, header and footer included. `help` shows what you can type; `tree` shows how it is organised.

- **Keep helpers out of the command list.** A public method without a `desc` is a hidden task: it runs from the command line and as a dependency. Make helpers `private`, wrap them in `no_commands`, or define them with `helper`.

- **Pass results, not instance variables.** Parallel dependencies each run on their own copy of the task object, so an `@ivar` set in one never reaches the task that depends on it. Return a value and read it with `dep_result(:name)` or `dep_results`; [`examples/bad.loki`](examples/bad.loki) shows the trap.

- **Let gates report, let guards stop.** A quality gate returns `:fail` so every gate runs and the summary shows all failures at once. A guard such as [`examples/confirm.loki`](examples/confirm.loki) raises `Asgard::Error` so nothing after it runs. A dependency's return value never stops its dependent; only an exit, `abort` or `raise` does.

- **Name shell configurations, not shells.** The name you give `shell` is yours: `shell :strict, "bash -eu -o pipefail"` names a bash configuration that stops at the first failing line, and `shell :uv, "uv run --script", ext: ".py"` names a way of running Python. `sh` and `shebang` take a name as an optional first argument (`sh :strict, "..."`); without one they run the `default_shell`, so `default_shell :strict` makes every plain `sh` fail fast.

- **Prefer `background: true` to a trailing `&`.** A managed job gets a name, a log and `asgard jobs stop`; a process detached with `&` leaves no record and must be found with `ps`.

- **Import conditionally.** `.loki` is plain Ruby: `import "quality_rails.loki" if ENV["RAILS_ROOT"]` keeps Rails-only gates out of non-Rails projects, and a block-form `depends_on` picks up whatever `*_check` tasks are loaded.

- **Trace loading when something is missing.** `RUBYOPT=-w asgard help` prints each file as `import` loads it; `ASGARD_TRACE=1` turns a one-line load error into the full backtrace with Ruby's "Did you mean?" hint.

---

## Development

```bash
git clone git@github.com:MadBomber/asgard.git
cd asgard
bundle install
bundle exec bin/asgard test_check  # run tests (95% coverage minimum enforced)
bundle exec bin/asgard quality     # every quality gate in parallel
bundle exec bin/asgard help        # exercise the CLI against this gem's own .loki
```

## Contributing

Bug reports and pull requests are welcome at https://github.com/MadBomber/asgard.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
