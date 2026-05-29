# Task Dependencies

`depends_on` declares what must run before a task. Asgard resolves the dependency graph at startup, validates it for cycles, and executes prerequisites automatically when a task is invoked.

!!! note
    `desc` and `depends_on` are independent — either can come first. Both must appear before the `def`.

---

## How It Works

When you run `asgard <task>`, Asgard:

1. Validates the full dependency graph for circular references (fails fast with a clear error).
2. Resolves the dependency stages for the requested task in order.
3. Executes each stage — running parallel groups in native Ruby threads.
4. Runs the task itself after all prerequisites complete.

**Deduplication:** each task runs at most once per `asgard` invocation, regardless of how many other tasks declare it as a dependency. This is enforced thread-safely via a class-level `Set` and `Mutex`.

---

## Sequential Dependencies

Bare symbols run one after another in the order declared:

```ruby
class Tasks
  desc "build", "Compile the project"
  def build = sh "rake build"

  depends_on :build
  desc "test", "Run the test suite"
  def test = sh "rake test"

  depends_on :test
  desc "release", "Publish the gem"
  def release = sh "bundle exec rake release"
end
```

```bash
asgard release   # build → test → release
```

Multiple sequential dependencies in a single `depends_on` call run left to right:

```ruby
depends_on :clean, :build, :test
desc "package", "Clean, build, and test"
def package = sh "rake package"
```

---

## Parallel Dependencies

Wrap symbols in an array to declare they can run concurrently. Asgard waits for all tasks in a parallel group to finish before moving to the next stage:

```ruby
class Tasks
  desc "lint", "Check code style"
  def lint = sh "bundle exec rubocop"

  desc "typecheck", "Run type checks"
  def typecheck = sh "bundle exec srb tc"

  depends_on [:lint, :typecheck]
  desc "test", "Run tests (after lint and typecheck)"
  def test = sh "bundle exec rake test"
end
```

```bash
asgard test   # lint ∥ typecheck → test
```

Parallel groups run in native Ruby threads. For CPU-bound work, keep in mind the GVL; for I/O-bound work (shell commands, network), true concurrency is achieved.

---

## Mixed Sequential and Parallel

Mix bare symbols and arrays in a single `depends_on` call. Execution proceeds stage by stage — each stage completes before the next begins:

```ruby
class Tasks
  desc "setup",  "Install dependencies"; def setup  = sh "bundle install"
  desc "lint",   "Check code style";     def lint   = sh "bundle exec rubocop"
  desc "build",  "Compile assets";       def build  = sh "rake assets:precompile"
  desc "test",   "Run tests";            def test   = sh "bundle exec rake test"
  desc "notify", "Post to Slack";        def notify = sh "curl $SLACK_WEBHOOK -d '{\"text\":\"done\"}'"

  # setup first, then lint+build in parallel, then test, then notify
  depends_on :setup, [:lint, :build], :test, :notify
  desc "ci", "Full CI pipeline"
  def ci = sh "echo 'CI complete'"
end
```

```bash
asgard ci
```

Execution order:

```
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

---

## Deduplication

Each task runs at most once per `asgard` invocation. If multiple tasks declare the same dependency, it executes only on its first encounter:

```ruby
class Tasks
  desc "setup", "Install gems"
  def setup = sh "bundle install"

  depends_on :setup
  desc "test", "Run tests"
  def test = sh "rake test"

  depends_on :setup
  desc "lint", "Check style"
  def lint = sh "rubocop"

  depends_on [:test, :lint]
  desc "ci", "Test and lint (setup runs once)"
  def ci = puts "done"
end
```

When `asgard ci` runs, `setup` executes once even though both `test` and `lint` declare it as a dependency. The deduplication set is managed with a `Mutex` so parallel groups are also safe.

---

## Circular Dependency Detection

Asgard validates the full dependency graph using [Dagwood](https://rubygems.org/gems/dagwood) before any task runs. A circular dependency produces a clean error and exits:

```ruby
class Tasks
  depends_on :b
  desc "a", "Task A"; def a = puts "a"

  depends_on :a
  desc "b", "Task B"; def b = puts "b"
end
```

```bash
asgard a
# asgard: circular dependency — TSort::Cyclic: ...
```

No backtrace is shown — just a single diagnostic line.

---

## depends_on Across Multiple Files

`depends_on` works across `.loki` files because all files reopen the same `class Tasks`. The dependency is recorded when the `def` is encountered, so load order matters:

```ruby
# build.loki
class Tasks
  desc "build", "Compile"
  def build = sh "rake build"
end

# test.loki
class Tasks
  depends_on :build           # build.loki must be loaded first
  desc "test", "Test"
  def test = sh "rake test"
end
```

Since `*.loki` files are loaded alphabetically, `build.loki` loads before `test.loki`. If you need to control load order, use explicit `require_relative` from `.loki`.

---

## depends_on Inside Subcommands

`depends_on` works within subcommand classes exactly as it does at the top level. Dependency scope is per-class:

```ruby
class DBCommands < Tasks
  desc "migrate", "Run migrations"
  def migrate = sh "rails db:migrate"

  desc "seed", "Load seed data"
  def seed = sh "rails db:seed"

  depends_on :migrate, :seed
  desc "reset", "Migrate then seed"
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

See [Subcommands](subcommands.md) for the full guide.
