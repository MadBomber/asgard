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

Multiple sequential dependencies in a single `depends_on` call run left to right:

```ruby
depends_on :clean, :build, :test
desc "Clean, build, and test"
def package = sh "rake package"
```

---

## Parallel Dependencies

Wrap symbols in an array to declare they can run concurrently. Asgard waits for all tasks in a parallel group to finish before moving to the next stage:

```ruby
class Tasks
  desc "Check code style"
  def lint = sh "bundle exec rubocop"

  desc "Run type checks"
  def typecheck = sh "bundle exec srb tc"

  depends_on [:lint, :typecheck]
  desc "Run tests (after lint and typecheck)"
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
  desc "Install gems"
  def setup = sh "bundle install"

  depends_on :setup
  desc "Run tests"
  def test = sh "rake test"

  depends_on :setup
  desc "Check style"
  def lint = sh "rubocop"

  depends_on [:test, :lint]
  desc "Test and lint (setup runs once)"
  def ci = puts "done"
end
```

When `asgard ci` runs, `setup` executes once even though both `test` and `lint` declare it as a dependency. The deduplication set is managed with a `Mutex` so parallel groups are also safe.

---

## Transitive Dependencies

When a dependency has its own dependencies, Asgard resolves them recursively before running the dependent task. The deduplication set ensures each task runs at most once regardless of how many paths lead to it.

Consider this graph:

```ruby
class Tasks
  desc "Fetch gems"
  def setup = sh "bundle install"

  depends_on :setup
  desc "Compile assets"
  def build = sh "rake assets:precompile"

  desc "Check code style"
  def lint = sh "bundle exec rubocop"

  depends_on :build, :lint, :setup
  desc "Run the full pipeline"
  def ci = puts "Done."
end
```

`ci` declares three sequential dependencies: `build`, `lint`, `setup`. But `build` itself depends on `setup`. The effective execution order is:

```
setup          ← run as build's prerequisite
  ↓
build
  ↓
lint
  ↓
(setup skipped — already done)
  ↓
ci
```

`setup` runs once — on its first encounter as `build`'s prerequisite. When `ci`'s own stage for `setup` is reached, the deduplication set skips it.

!!! tip
    When a task is both a transitive dependency and a direct dependency, declare it only where it logically belongs — as a prerequisite of the task that needs it. Declaring it redundantly at the top level is harmless (deduplication handles it) but adds noise.

---

## Circular Dependency Detection

Asgard validates the full dependency graph using stdlib [TSort](https://docs.ruby-lang.org/en/master/TSort.html) before any task runs. A circular dependency produces a clean error and exits:

```ruby
class Tasks
  depends_on :b
  desc "Task A"; def a = puts "a"

  depends_on :a
  desc "Task B"; def b = puts "b"
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
  desc "Compile"
  def build = sh "rake build"
end

# test.loki
class Tasks
  depends_on :build           # build.loki must be loaded first
  desc "Test"
  def test = sh "rake test"
end
```

Because `*.loki` files are loaded alphabetically when `import "*.loki"` is used, `build.loki` loads before `test.loki`. If you need to control load order precisely, use explicit `import` calls with full filenames rather than a glob.

---

## Dynamic Dependencies (Proc / Block Form)

`depends_on` normally takes a fixed list, recorded the moment the `def` right after it is encountered — which is why load order matters, as above. Pass a `Proc` or lambda instead — or, equivalently, a block — and that list is computed *later*, after every `.loki` file has finished loading, rather than at the point `depends_on` itself is evaluated:

```ruby
depends_on -> { [all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)] }
desc "Run every *_check quality gate task in parallel"
def quality
  # ...
end

depends_on { [all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)] }
desc "Same thing, written as a block"
def quality2
  # ...
end
```

This solves exactly the "load order matters" problem from the previous section: a plain array can only name tasks that already exist in `.loki` files loaded *before* this one. A Proc/block is resolved once every file has loaded, so it can safely reference a task defined in a file that hasn't been imported yet at the point `depends_on` is written — including one that only exists conditionally, e.g. a Rails-specific task file imported with `import "quality_rails.loki" if defined?(Rails)`. `depends_on` accepts task arguments *or* a block, never both — combining them raises `Asgard::Error`.

**Shape:** the Proc/block must return exactly what the plain-array form would receive as its splat arguments — an array of stages, each a `Symbol`/`String` (sequential) or an `Array` of `Symbol`/`String` (parallel group), nested no deeper than that. The example above returns `[[:a_check, :b_check, :c_check]]`: one stage, containing every matching task, all running in parallel — the same shape as `depends_on [:a_check, :b_check, :c_check]`. This shape is validated once the result comes back — a bad return value (wrong type, a stage that isn't a Symbol/String/Array, a leaf inside a parallel group that isn't a Symbol/String, or nesting more than one level deep) raises `Asgard::Error` naming the task and the offending value, instead of failing later with an opaque `NoMethodError`:

```bash
asgard quality
# asgard: depends_on proc/block for 'quality' returned invalid stage 123 (Integer); expected a Symbol, String, or Array of them
```

**When it runs:** once, when `validate_deps!` runs (right after the `.loki` chain finishes loading, before any task dispatches). The resolved result replaces the Proc/block in the dependency table, so cycle detection, undefined-task checks, and arity checks all run against the *resolved* list — a Proc/block that references an undefined task, or that itself introduces a cycle, is caught at startup exactly like a plain array would be:

```bash
asgard quality
# asgard: undefined task(s) in depends_on: ghost_check
```

**`self` inside the Proc/block:** since it's written directly in a `class Tasks` body, it lexically captures that class as `self` — so it can call `all_commands`, `_deps`, or any other class-level method bare, without a `self.class.` prefix, even though it's actually invoked later from inside `validate_deps!`.

**If the Proc/block raises**, the error is caught and re-raised as `Asgard::Error` naming the task it was declared for:

```
asgard: depends_on proc for 'quality' raised RuntimeError: boom
```

!!! tip
    Reach for this only when the dependency list genuinely can't be known until every file has loaded — like "every task whose name ends in `_check`," discovered across several `.loki` files. For a fixed, known-upfront list, the plain array form is simpler and reads just as clearly.

---

## depends_on Inside Subcommands

`depends_on` works within subcommand classes exactly as it does at the top level. Dependency scope is per-class:

```ruby
class DBCommands < Tasks
  desc "Run migrations"
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

See [Subcommands](subcommands.md) for the full guide.
