# Examples

The asgard repository ships working `.loki` files in its `examples/` directory, one for each feature, plus the gem's own task files at the repository root, which are a real multi-file project in daily use. This page says what each one shows and how to run it. Copy whatever is useful into your own project.

---

## Running the Examples Directory

`examples/` has its own `.loki`, so it is a project in its own right:

```bash
git clone https://github.com/MadBomber/asgard.git
cd asgard/examples
asgard help
```

Its `.loki` loads everything else explicitly:

```ruby
# examples/.loki
import "*.loki"                      # every sibling task file, alphabetically
import "subdir/import_demo.loki"     # one file from a subdirectory
```

Three examples are separate projects with their own `.loki` and must be run from their own directory: `depends_on_block/good`, `depends_on_block/bad` and `watcher_examples`.

!!! note
    `concurrent.loki` exists to be run, not read: its point is output that changes from run to run.

---

## `kitchen_sink.loki`

Every Thor word and most of asgard's, in one file. Task names avoid the gem's own (`test`, `build`, `quality`, `install`, `release`) so the file can sit beside them.

- `@@app_name` and `@@build_dir` class variables shared by every task
- `private` computed values (`version`, `sha`, `branch`) with memoization
- `class_option :dry_run` and `class_option :env` with `enum`, on every task
- `default_task :greet` and `map` aliases (`g`, `ck`, `rp`, `pl`)
- A positional parameter with a default (`hello NAME`)
- All five option types (`:string`, `:boolean`, `:numeric`, `:array`, `:hash`) on `compile`
- `required: true`, `enum:` and `banner:` on `deploy`
- `long_desc` with `\x5` line breaks on `report`
- Sequential, parallel and mixed `depends_on` (`spec`, `check`, `pipeline`)
- `debug?` and `verbose?` on `status`
- `sh` with one line and with a heredoc (`env_info`, `bootstrap`)
- A `no_commands` helper and a `private` helper

```bash
asgard                       # the default task, greet
asgard hello Alice
asgard compile --jobs 4 --tags debug release --defines VERSION:2 MODE:fast
asgard deploy --strategy rolling
asgard deploy                # No value provided for required options '--strategy'
asgard help report           # the long_desc
asgard pipeline              # check → compile ∥ spec → pack → pipeline
asgard status --verbose --debug
```

See [Defining Tasks](tasks.md), [Options & Flags](options.md) and [Dependencies](dependencies.md).

---

## `server_subcommands.loki`

A subcommand group, `asgard server ...`, in a class that inherits from `Tasks`:

- `ServerCommands < Tasks` registered with `subcommand "server", ServerCommands`
- Per-command options (`--port`, `--daemon`, `--workers`, `--log`, `--force`, `--wait`)
- A `helper` (`server_port`) that reads the port saved by `start` so `stop` and `restart` use the same one
- `depends_on :stop` inside the group, so `restart` stops first

```bash
asgard server                    # the group's own help
asgard server start -p 4000 --workers 4 --daemon
asgard server status
asgard server stop --force
asgard server restart            # stop → restart, on the saved port
```

See [Subcommands](subcommands.md).

---

## `db_subcommands.loki`

A second group, `asgard db ...`, with a longer dependency chain:

- `migrate [VERSION]`, `rollback [STEPS]`, `seed [FILE]` with optional positional parameters
- `depends_on :rollback, :migrate, :seed` on `reset`
- `long_desc` and `enum` validation inside a subcommand class

```bash
asgard db migrate 20240101120000 --dry-run
asgard db rollback 3
asgard db seed --env staging
asgard db reset                  # rollback → migrate → seed → reset
asgard db console --env staging
```

---

## `concurrent.loki`

Proof that a parallel stage really runs at the same time. Three workers each print a letter ten times with random pauses; `finish` depends on all three.

```ruby
depends_on :start, [:worker_a, :worker_b, :worker_c]
desc "Print end marker after all workers complete"
def finish = puts "\nfini - the end of concurrent task demo"
```

```bash
asgard finish
```

```
starting demo of concurrent task execution ...
ABCBACBACBABCBACBACBCABCABACBA
fini - the end of concurrent task demo
```

The letters interleave differently every run. The file sets `$stdout.sync = true` so each `print` appears at once. See [Parallel Dependencies](dependencies.md#parallel-dependencies).

---

## `do.loki`

Asgard runs one task per command line. This example adds a `do` task that runs several, the way `rake a b c` or `just a b c` does. It is an ordinary user task, so you can copy it into any `.loki`:

```ruby
require "shellwords"

class Tasks
  # Not a task (a class method), so it can be tested on its own:
  #   Tasks.do_steps("lint, hello Alice") #=> [["lint"], ["hello", "Alice"]]
  def self.do_steps(line)
    line.include?(",") ? line.split(",").map { |step| Shellwords.split(step) }.reject(&:empty?)
                       : Shellwords.split(line).map { |word| [word] }
  end

  desc "do STEPS...", "Run several tasks in sequence, e.g. `asgard do hello Alice, farewell Bob --formal`"
  stop_on_unknown_option! :do
  def do(*words)
    steps = self.class.do_steps(words.join(" "))
    raise Asgard::Error, "do: no tasks given" if steps.empty?

    steps.each do |name, *args|
      raise Asgard::Error, "do: unknown task '#{name}'" if name == "do" || !self.class.all_commands.key?(name)
      # Each step is parsed as if typed on its own command line.
      return :fail if self.class.send(:dispatch, nil, [name, *args], nil, shell: shell) == :fail
    end
  end
end
```

Steps are comma-separated so a step can carry its own arguments and options; with no commas, every word is a task.

```bash
asgard do greet finish
asgard do hello Alice, farewell Bob --formal, finish
```

```
Hello, Alice!
Goodbye, Bob.
...
```

- Each step's arguments and options work exactly as they would alone.
- The sequence stops at the first failure: a failing `sh` exits asgard, and a step that returns `:fail` makes `do` return `:fail` (exit 1).
- Every task runs at most once per asgard invocation, so `asgard do hello Alice, hello Bob` greets only Alice, and a dependency shared by several steps runs once.

---

## `confirm.loki`

A guard: list `confirm` first in a dangerous task's `depends_on` and the task only runs after you answer yes. Also an ordinary user task, worth copying:

```ruby
class Tasks
  # Not a task, so it can be tested on its own:
  #   Tasks.confirmed?("y", yes_env: nil) #=> true
  def self.confirmed?(answer, yes_env:)
    return true if yes_env && !yes_env.empty?

    %w[y yes].include?(answer.to_s.strip.downcase)
  end

  desc "Ask before running the task that depends on this", hide: true
  def confirm
    command = "asgard #{ARGV.join(' ')}"
    yes_env = env(:asgard_yes, "")
    return if self.class.confirmed?(nil, yes_env:)
    raise Asgard::Error, "refusing `#{command}`: no terminal to confirm on (set ASGARD_YES=1)" unless $stdin.tty?

    answer = ask("Really run `#{command}`? [y/N]")
    raise Asgard::Error, "aborted `#{command}`" unless self.class.confirmed?(answer, yes_env:)
  end

  depends_on :confirm
  desc "Pretend to drop and recreate the database (demo for confirm)"
  def reset_database
    puts "Database reset."
  end
end
```

```bash
asgard reset_database
# Really run `asgard reset_database`? [y/N] n
# asgard: aborted `asgard reset_database`          (exit 1)

ASGARD_YES=1 asgard reset_database                 # no question: scripts and CI
# Database reset.
```

Points the example makes:

- Answering no **raises** `Asgard::Error`, which stops everything that has not run yet. Returning `:fail` would not: a dependency's return value never stops the task that depends on it.
- A dependency does not know which task asked for it, so the question shows the whole command line.
- With no terminal to ask on (a schedule, the watcher, a pipe) it refuses unless `ASGARD_YES` is set, rather than hanging.
- `hide: true` keeps `confirm` out of `asgard help`.
- It runs once per invocation, so `asgard do reset_database, drop_cache` asks once for the whole line. Keep it in its own first stage: in `depends_on [:confirm, :backup]`, `backup` runs while the question waits.

`ASGARD_YES` is the example's own variable, not something asgard reads. See [When a Dependency Fails](dependencies.md#when-a-dependency-fails).

---

## `env_usage.loki` and `.env`

Reading variables with `env` after loading a dotenv file:

```ruby
class Tasks
  # loki_up finds .env in this directory or any ancestor, so the task
  # works from any subdirectory.
  dotenv loki_up(".env") || ".env"

  desc "Print environment variable values resolved via env()"
  def env_demo
    puts <<~OUT
      APP_NAME     : #{env(:app_name)}
      PORT         : #{env(:port)}
      API_KEY      : #{env(:api_key)}
      DATABASE_URL : #{env(:database_url)}
      LOG_LEVEL    : #{env(:log_level, "info")}
    OUT
  end
end
```

```
# examples/.env
APP_NAME=my_app
PORT=4000
API_KEY=secret-key-abc123
DATABASE_URL=postgres://localhost/my_app_dev
```

```bash
asgard env_demo
```

```
APP_NAME     : my_app
PORT         : 4000
API_KEY      : secret-key-abc123
DATABASE_URL : postgres://localhost/my_app_dev
LOG_LEVEL    : info
```

`LOG_LEVEL` is not in `.env`, so `env(:log_level, "info")` returns the default. See [Environment Variables](environment.md).

---

## `subdir/`

Three files that show `import` across a directory boundary and `import_up` back out of one:

| File | What it does |
|---|---|
| `subdir/import_demo.loki` | Defines `subdir_task`; loaded by `examples/.loki` with `import "subdir/import_demo.loki"` |
| `subdir/.loki` | Makes `subdir/` a project of its own when you run asgard from inside it; loads `import_up_demo.loki` |
| `subdir/import_up_demo.loki` | Calls `import_up "env_usage.loki"`, which walks up and finds `examples/env_usage.loki` without a hard-coded relative path |

```bash
cd examples;        asgard subdir_task      # Loaded from examples/subdir/import_demo.loki
cd examples/subdir; asgard env_demo         # found one directory up by import_up
```

See [Task Files](task-files.md).

---

## `depends_on_block/good/` and `depends_on_block/bad/`

Two one-file projects for the block form of `depends_on`, which computes the dependency list after every file has loaded. Run each from its own directory.

**`good/.loki`** defines `a_check`, `b_check`, `c_check` and three tasks that gather them:

```ruby
depends_on { [all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)] }
desc "Run every *_check task in parallel, then report"
def quality = puts "quality: all *_check tasks passed"

depends_on { [:setup, %i[a_check b_check], :teardown] }
desc "setup, then a_check+b_check in parallel, then teardown"
def full_cycle = puts "full_cycle: done"

depends_on do
  all_checks  = all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)
  slow_checks = %i[c_check]
  [:setup, all_checks - slow_checks, :teardown]
end
desc "setup, then every *_check except the slow ones, then teardown"
def smoke = puts "smoke: done"
```

```bash
cd examples/depends_on_block/good
asgard quality
```

```
running a_check ...
running b_check ...
running c_check ...
quality: all *_check tasks passed
```

**`bad/.loki`** wraps the list in one Array too many, `[[ ... ]]`. The result is checked before any task runs:

```bash
cd examples/depends_on_block/bad
asgard quality
```

```
asgard: depends_on proc/block for 'quality' returned invalid dependency [:a_check, :b_check, :c_check] (Array) in a parallel group; expected a Symbol or String
```

See [Dynamic Dependencies](dependencies.md#dynamic-dependencies).

---

## `bad.loki`

Why an instance variable is the wrong way to pass results out of parallel dependencies, and why `dep_result` exists. Four workers run in one parallel stage; each sets `@hits` to a thousand and also returns it:

```bash
asgard bad_race
```

```
@hits after the parallel stage: nil
dep_result(:racer_1): 1000
sum of dep_results: 4000
```

Parallel dependencies each run on their own copy of the task object, so the `@hits` each worker sets never reaches `bad_race`. The return values do: read one with `dep_result(:racer_1)` or all of them with `dep_results`. See [Passing Results Between Tasks](dependencies.md#passing-results-between-tasks).
---

## `watcher_examples/`

A small project whose tasks run when its files change: four `watch` declarations covering a glob, a directory with `only:`, `ignore:` and `env:`, an `events:` filter with `debounce:`, and a second watch of one task with `as:`. The `lib/`, `bin/`, `docs/` and `data/` directories hold one placeholder file each so there is something to edit at once.

```bash
cd examples/watcher_examples
asgard watcher start
echo '# a change' >> lib/greeter.rb
asgard watcher log
asgard watcher list
asgard watcher stop
```

Every task also runs by hand, when `changes` is empty. Its `README.md` walks through the whole session with expected output; so does [Watched Files](watch.md).

---

## The asgard Repository Itself

The repository root is a multi-file project that builds, tests and releases the gem. It is the best example of a `.loki` layout in real use.

### `.loki`

The entry point: imports, shared values, a `header` built from a `helper`, a `watch`, and a `default_task`.

```ruby
import "quality.loki"
import "quality_rails.loki" if ENV["RAILS_ROOT"]   # a conditional import
import "gem_tasks.loki"
import "git.loki"
import "doc_tasks.loki"
import "xyzzy.loki"                                 # a deliberate override, for --doctor

class Tasks
  @@project      ||= "asgard".freeze
  @@project_desc ||= "CLI-task runner"

  watch :test_check, paths: %w[lib test], only: /\.rb\z/   # rerun the tests on save

  helper(:project_version) do
    @@project_version ||= loki_up.dirname.join("lib/#{@@project}/version.rb").read.match(/VERSION\s*=\s*"([^"]+)"/)[1].freeze
  end

  default_task :quality

  header <<~HEAD
    Project:  #{@@project} (v#{project_version}) - #{@@project_desc}
    Root Dir: #{loki_up.parent}
    Default task: #{default_task}
  HEAD
end
```

### `quality.loki`

The quality gates, and the convention that ties them together. Every gate is a task named `*_check` that writes its full output to `<gate>_output.txt`, prints one summary line, and **returns** a status: `:pass`, `:fail`, `:warn` (ran, non-blocking advice) or `:skip` (the tool is not installed). `quality` discovers every `*_check` task with a block `depends_on`, runs them all in parallel, reads every result at once with `dep_results`, and prints a summary table; it aborts only when a gate returned `:fail`.

```ruby
desc "Run every *_check quality gate task in parallel"
depends_on -> { [all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)] }
def quality
  results = dep_results.sort.to_h { |name, status| [quality_gate_label(name.to_s), status] }
  print_quality_summary(results)
end
```

Most gates are one call to a `run_gate` helper (defined in a `no_commands` block) that runs a command, saves its output, picks the summary line with a Regexp and turns the exit status into `:pass` or the gate's failure status:

```ruby
desc "Report code smells with Reek (advisory: warns, never fails)"
def reek_check = run_gate(:reek, "Reek", "bundle exec reek lib", summary: /total warnings?/, on_fail: :warn)
```

Because a `*_check` task returns `:fail` rather than exiting, every gate runs to the end and the summary shows all failures at once. Run alone (`asgard rubocop_check`), a gate that returns `:fail` still makes asgard exit 1.

```bash
asgard quality
```

```
Tests: 412 runs, 1193 assertions, 0 failures, 0 errors, 0 skips (see test_output.txt)
RuboCop: 61 files inspected, no offenses detected (see rubocop_output.txt)
...
============================================================
Quality Gate Summary
============================================================
  [PASS] Tests + Coverage
  [PASS] RuboCop
  [SKIP] Typos
  ...
------------------------------------------------------------
  9 pass, 1 skip
============================================================

All quality gates passed.
```

### `gem_tasks.loki`

`console`, `build` (depends on `quality`), `install` (depends on `build`) and `release` (runs only on `main`, then depends on `build`, asks for confirmation unless `--yes`, refuses a dirty working tree or an existing tag). A plain `sh` sequence does the work; `project_version` comes from the `helper` in `.loki`.

### `git.loki`

Three one-liners: `push`, `pull` (fast-forward only), `fetch`. The smallest useful task file.

### `doc_tasks.loki`

A subcommand group, `asgard doc ...`, that works with an MkDocs site or a Bridgetown site. Each task first calls the private `doc_engine` helper, which looks in the repo root for `mkdocs.yml` or `bridgetown.config.yml`, sets the engine and the commands to run for it, and stops with an error when neither file is there. `open` depends on `serve`, which depends on `build`, which depends on `install`. The server starts as a background job and asgard returns at once; when the job is already running it is not started again, and `build` skips a site that is newer than every file in its source folder and its config file. `open` waits for the server to answer, then opens the site, `http://localhost:8000/` for MkDocs or `http://localhost:4000/` for Bridgetown, in the default browser, or in Google Chrome with `--chrome`. The commands run from the repo root, so the tasks work from any subdirectory.

```ruby
class DocCommands < Tasks
  default_task :open

  # Each engine's config file, its default source and output folders, the
  # commands the doc tasks run for it, and the port its server listens on
  # by default.
  DOC_ENGINES = {
    mkdocs:     { config: "mkdocs.yml", source: "docs", output: "site",
                  build: "mkdocs build", serve: "mkdocs serve", port: 8000 },
    bridgetown: { config: "bridgetown.config.yml", source: "src", output: "output",
                  build: "bin/bridgetown build", serve: "bin/bridgetown start", port: 4000 },
  }.freeze

  # Seconds `doc open` waits for a server that has just started to answer.
  SERVER_WAIT = 30

  desc "Install the documentation engine (mkdocs with Homebrew, Bridgetown with bundle install)"
  def install
    case doc_engine
    when :mkdocs     then install_mkdocs
    when :bridgetown then Dir.chdir(@doc_root) { sh "bundle install" }
    end
  end

  desc "Build the documentation site, unless it is up to date"
  depends_on :install
  def build
    doc_engine
    return puts "doc: #{@output.relative_path_from(@doc_root)} is up to date" if built?(@output, [@config, @source])

    Dir.chdir(@doc_root) { sh @build_command }
  end

  # A serve job that is already running is not started again: the call
  # prints "serve-1 already running" and returns.
  desc "Serve the documentation as a background job (see `asgard jobs`)"
  depends_on :build
  def serve
    doc_engine
    Dir.chdir(@doc_root) { sh @serve_command, background: true }
  end

  desc "Open the served documentation in the default browser"
  option :chrome, type: :boolean, default: false, desc: "Use Google Chrome instead of the default browser"
  depends_on :serve
  def open
    doc_engine
    abort "doc: nothing answered at #{@doc_url} (see `asgard jobs log serve-1`)" unless server_up?(@port, SERVER_WAIT)

    sh browser_command(@doc_url, chrome: options.chrome?)
  end

  private

  # Finds the engine whose config file is in +root+ (the repo root by
  # default), sets @engine, @doc_root, @config, @source, @output,
  # @build_command, @serve_command, @port and @doc_url, and returns @engine.
  # Aborts when neither config file is there.
  def doc_engine(root = loki_up.dirname)
    @engine, settings = DOC_ENGINES.find { |_, engine| root.join(engine[:config]).file? }
    abort "doc: found neither mkdocs.yml nor bridgetown.config.yml in #{root}" unless @engine

    @doc_root      = root
    @config, @source, @output = settings.values_at(:config, :source, :output).map { root.join(it) }
    @build_command = settings[:build]
    @serve_command = settings[:serve]
    @port          = settings[:port]
    @doc_url       = "http://localhost:#{@port}/"
    @engine
  end

  # true when +output+'s index.html is newer than every file in +sources+
  # (files, or folders searched all the way down).
  def built?(output, sources)
    index = output.join("index.html")
    return false unless index.file?

    files = sources.flat_map { |s| s.directory? ? s.glob("**/*").select(&:file?) : [s] }
    files.all? { it.mtime <= index.mtime }
  end

  # true once something accepts connections on localhost:+port+; false
  # when nothing has within +wait+ seconds.
  def server_up?(port, wait)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    begin
      Socket.tcp("localhost", port, connect_timeout: 1).close
      true
    rescue SystemCallError
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.25
      retry
    end
  end

  # The macOS command that opens +url+ in the default browser, or in Google
  # Chrome when +chrome+ is true.
  def browser_command(url, chrome: false)
    chrome ? "open -a 'Google Chrome' #{url}" : "open #{url}"
  end

  def install_mkdocs
    mkdocs = `which mkdocs`.strip
    return puts "mkdocs: #{mkdocs}" unless mkdocs.empty?

    sh "brew install mkdocs"
  end
end

class Tasks
  desc "doc SUBCOMMAND", "Install, build and serve the documentation (MkDocs or Bridgetown)"
  subcommand "doc", DocCommands
end
```

```bash
asgard doc serve                   # started serve-1 (pid 48213), log: ...
asgard doc open                    # the site in the default browser
asgard doc                         # the same: open is the group's default task
asgard doc open --chrome           # the site in Google Chrome
asgard jobs                        # lists it
asgard jobs log serve-1            # what the server has printed so far
asgard jobs stop serve
```

The group's `install` and `build` don't clash with the top-level ones in `gem_tasks.loki`: inside `DocCommands` they replace the inherited tasks, and `asgard install` is unchanged. To support another engine, add its config file and commands to `DOC_ENGINES`, plus an `install` branch. See [Subcommands](subcommands.md) and [Background Jobs](jobs.md).

### `xyzzy.loki`

Defines a `xyzzy` task; `.loki`, loaded after it, defines `xyzzy` again. The first definition is silently dead, and `asgard --doctor` says so:

```
  .loki
    xyzzy  .loki:26   active — redefines xyzzy.loki:6

  xyzzy.loki
    xyzzy  xyzzy.loki:6   OVERRIDDEN by .loki:26 — never callable
```

See [Help & Diagnostics](diagnostics.md).

### `quality_rails.loki`

Rails-only gates (`brakeman_check`, `rails_best_practices_check`, `active_record_doctor_check`), imported by `.loki` only when `RAILS_ROOT` is set. Nothing else needs to change for `quality` to pick them up: its block `depends_on` finds every `*_check` task that is loaded.

---

## Summary

| Example | Shows |
|---|---|
| `kitchen_sink.loki` | Every option type, `long_desc`, `map`, `default_task`, `class_option`, all `depends_on` shapes, helpers |
| `server_subcommands.loki` | A subcommand group with options, a `helper`, `depends_on` inside the group |
| `db_subcommands.loki` | A subcommand group with a dependency chain, `enum`, `long_desc` |
| `concurrent.loki` | A parallel stage really running at once |
| `do.loki` | Several tasks from one command line, with per-step arguments |
| `confirm.loki` | A guard dependency that asks before a dangerous task |
| `env_usage.loki` | `dotenv`, `loki_up(".env")` and `env` with defaults |
| `subdir/` | `import` from a subdirectory, `import_up` to an ancestor |
| `depends_on_block/good`, `bad` | The block form of `depends_on`, and its shape error |
| `bad.loki` | Why parallel tasks must not share instance variables |
| `watcher_examples/` | Four `watch` declarations and the `changes` accessor |
| repository root | A real multi-file project: `*_check` gates, `dep_result`, conditional imports and tasks, a background job, an override caught by `--doctor` |
