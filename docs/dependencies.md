# Dependencies

`depends_on` says what must run before a task. You list the prerequisites above the task, and asgard runs them in order, runs groups of them at the same time where you ask for that, and makes sure each one runs only once no matter how many tasks need it. Dependencies are what turn a pile of commands into a pipeline.

The simplest form is one task that needs another:

```ruby
class Tasks
  desc "Compile the project"
  def build = sh "rake build"

  depends_on :build
  desc "Run the test suite"
  def test = sh "rake test"
end
```

```bash
asgard test    # runs build, then test
```

!!! note
    `desc` and `depends_on` both go above the `def`, in either order. `depends_on` always attaches to the very next method.

---

## How It Works

When you run `asgard <task>`:

1. Every `.loki` file loads and every dependency list is checked: unknown task names, cycles and a few other mistakes stop asgard before anything runs (see [Startup Validation](#startup-validation)).
2. The task's prerequisites run stage by stage. A stage is one task, or a group of tasks that run at the same time. The next stage starts when every task in the current one has finished.
3. The task itself runs.

Each task runs at most once per `asgard` command, however many other tasks depend on it. A prerequisite that fails stops the whole run with a non-zero exit status.

---

## Sequential Dependencies

Bare task names run one after another, left to right:

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

Several names in one `depends_on` also run in order:

```ruby
depends_on :clean, :build, :test
desc "Clean, build, and test"
def package = sh "rake package"
```

```bash
asgard package   # clean → build → test → package
```

---

## Parallel Dependencies

Wrap names in an array and they run at the same time. Asgard waits for the whole group before moving on:

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

Parallel tasks run in threads inside one asgard process. For shell commands and other work that waits on the outside world, that is real concurrency: two `sh` calls in two parallel tasks are two processes running at once. The output of parallel tasks interleaves on the terminal; `examples/concurrent.loki` in the repository shows this on purpose.

---

## Mixed Sequential and Parallel

Mix bare names and arrays in one `depends_on`. Each element is a stage:

```ruby
class Tasks
  desc "Install dependencies"; def setup  = sh "bundle install"
  desc "Check code style";     def lint   = sh "bundle exec rubocop"
  desc "Compile assets";       def build  = sh "rake assets:precompile"
  desc "Run tests";            def test   = sh "bundle exec rake test"
  desc "Post to Slack";        def notify = sh "curl $SLACK_WEBHOOK -d '{\"text\":\"done\"}'"

  # setup first, then lint and build together, then test, then notify
  depends_on :setup, [:lint, :build], :test, :notify
  desc "Full CI pipeline"
  def ci = puts "CI complete"
end
```

```bash
asgard ci
```

<figure markdown>
--8<-- "docs/assets/images/deps-stages.svg"
<figcaption>Each element of <code>depends_on</code> is one stage. An array is a stage whose tasks run together.</figcaption>
</figure>

```
setup
  ↓
lint ∥ build    (at the same time)
  ↓
test
  ↓
notify
  ↓
ci
```

---

## Each Task Runs Once

A task that several other tasks depend on runs the first time it is needed and is skipped after that:

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

```bash
asgard ci   # setup once, then test ∥ lint, then ci
```

Here `test` and `lint` start together and both want `setup`. One of them runs it; the other waits until it has finished rather than running it a second time or starting early. The guarantee holds across parallel groups, across files and across subcommands: one `asgard` command, one run per task.

### Transitive Dependencies

A prerequisite's own prerequisites run first, recursively:

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

```bash
asgard ci
```

```
setup          (as build's prerequisite)
  ↓
build
  ↓
lint
  ↓
(setup skipped: already done)
  ↓
ci
```

!!! tip
    Declare a task where it logically belongs, as a prerequisite of the task that needs it. Naming it again further up is harmless (it runs once either way) but adds noise.

---

## Dependencies Across Files

All `.loki` files reopen the same `Tasks` class, so a task in one file may depend on a task in another. Names are checked once every file has loaded, so the order in which the files load does not matter:

```ruby
# test.loki
class Tasks
  depends_on :build        # defined in build.loki, which may load before or after this file
  desc "Test"
  def test = sh "rake test"
end
```

```ruby
# build.loki
class Tasks
  desc "Compile"
  def build = sh "rake build"
end
```

What does depend on load order is a task name defined twice: the later definition silently replaces the earlier one, including its `depends_on`. See [Task Files](task-files.md#task-name-overloading) and [Help & Diagnostics](diagnostics.md) for how `asgard --doctor` finds that.

---

## When a Dependency Fails

A failed prerequisite stops the run. How it stops depends on what failed:

- **A failing `sh` or `shebang`**, or an `abort`, ends asgard with that command's exit status. The task that depended on it never starts. This is the normal case: `asgard release` with a failing test suite exits with the test runner's status.
- **An exception** raised inside a dependency propagates and asgard reports it. Raise `Asgard::Error` for a clean one-line message: `asgard: <message>`, exit 1.

```ruby
class Tasks
  desc "Refuse to deploy from a dirty tree"
  def clean_tree
    raise Asgard::Error, "commit or stash your changes first" unless `git status --porcelain`.strip.empty?
  end

  depends_on :clean_tree
  desc "Deploy to production"
  def deploy = sh "cap production deploy"
end
```

```bash
asgard deploy
# asgard: commit or stash your changes first
# (exit 1)
```

### A Return Value Never Stops Anything

Only an exit or an exception stops a dependent task. A dependency that *returns* something, even `:fail` or `false`, has succeeded as far as the pipeline is concerned. (Returning `:fail` from the task you typed on the command line does make asgard exit 1, which is how the quality-gate pattern below reports failure, but it does not stop a task that depends on it.) To guard a task, raise or let a command fail. `examples/confirm.loki` in the repository is a guard task built this way: it asks "Really run `asgard reset_database`?" and raises `Asgard::Error` on anything but yes. See [Examples](examples.md#confirmloki).

### Failure in a Parallel Group

When one task in a parallel group fails, asgard waits for every other task in the group to finish before reporting, so no subprocess is left running on its own. One failure is reported the same way it would be on its own: a failing command exits asgard with its status, an exception propagates. When more than one task fails, each is named on stderr and the run ends with an error listing them:

```
asgard: dependency 'lint' failed: exit 1
asgard: dependency 'typecheck' failed: RuntimeError: boom
asgard: parallel dependencies failed: lint, typecheck
```

A task that is waiting for a shared prerequisite in another thread does not run if that prerequisite fails. With `ci` depending on `[test, lint]` and both depending on `setup`, a failing `setup` stops `test`, `lint` and `ci` alike, and asgard exits with `setup`'s status.

---

## Passing Results Between Tasks

A task's return value is kept, and the task that depends on it can read it with `dep_result`. This is how a summary task collects what its prerequisites found. The example is the pattern the asgard repository uses for its own quality gates: every `*_check` task returns `:pass`, `:fail`, `:warn` or `:skip`, and `quality` prints a table:

```ruby
class Tasks
  desc "Run the test suite"
  def test_check
    output = `bundle exec rake test 2>&1`
    File.write("test_output.txt", output)
    $?.success? ? :pass : :fail
  end

  desc "Check code style"
  def rubocop_check
    output = `bundle exec rubocop 2>&1`
    File.write("rubocop_output.txt", output)
    $?.success? ? :pass : :fail
  end

  depends_on [:test_check, :rubocop_check]
  desc "Run every check in parallel, then report"
  def quality
    dep_results.each { |name, status| puts "  #{status.to_s.upcase.ljust(5)} #{name}" }
    failed = dep_results.values.count(:fail)
    abort "#{failed} check(s) failed" unless failed.zero?
    puts "All checks passed."
  end
end
```

```bash
asgard quality
```

```
  PASS  test_check
  FAIL  rubocop_check
1 check(s) failed
```

- `dep_result(:test_check)` is the return value of one direct dependency.
- `dep_results` is a Hash of every direct dependency's name to its return value.

Both read the dependencies of the task that is running, not of tasks further down the chain. A check that uses backticks or `system` rather than `sh` can report its result as a value instead of ending asgard; see [Exit on Failure](shell.md#exit-on-failure).

!!! warning "Parallel dependencies do not share instance variables"
    Tasks in one parallel group each run on their own copy of the task object, so an `@ivar` set by a parallel dependency is not visible to the task that depends on it. Sequential dependencies do share it, which is why the difference can surprise you when a `depends_on :a, :b` later becomes `depends_on [:a, :b]`. Pass values with `dep_result` instead; `examples/bad.loki` in the repository shows an `@ivar` coming back `nil` while `dep_result` carries the value.

---

## Startup Validation

Before any task runs, asgard checks every dependency list in every task class and stops with one line on the first problem. No backtrace, exit 1.

**Circular dependencies**

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
# asgard: circular dependency — topological sort failed: [:a, :b]
```

**A dependency that is not a task**

```bash
asgard ci
# asgard: undefined task(s) in depends_on: ghost_check
```

A private method is not a task, so `depends_on :my_helper` is undefined even though the method exists. Make it a task or call it from the task body.

**A `depends_on` with nothing after it**

A `depends_on` at the end of a class body, or followed only by `private` methods, has no task to attach to:

```bash
asgard
# asgard: depends_on(build, test) declared without a following task definition
```

**A dependency that needs arguments**

A task with required positional parameters cannot be a dependency, because nothing would supply them:

```ruby
desc "greet NAME", "Greet NAME"
def greet(name) = puts "Hello, #{name}"

depends_on :greet
desc "Welcome"
def welcome = puts "welcome"
```

```bash
asgard welcome
# asgard: task 'greet' has 1 required argument(s) and cannot be used as a dependency
```

Give the parameter a default (`def greet(name = "World")`) or read the value from an option or environment variable instead.

`asgard --doctor` reports the same problems without stopping at the first one; see [Help & Diagnostics](diagnostics.md).

---

## Dynamic Dependencies

A plain `depends_on` list is fixed when you write it. Sometimes the list has to be discovered: "every task whose name ends in `_check`", wherever it is defined, including a file that is only imported on some machines. For that, give `depends_on` a block, or a lambda, instead of a list. It is called once, after every `.loki` file has loaded, and must return the same shape a plain list would be:

```ruby
depends_on { [all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)] }
desc "Run every *_check task in parallel, then report"
def quality
  dep_results.each { |name, status| puts "#{status} #{name}" }
end

depends_on -> { [all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)] }
desc "The same thing, written as a lambda"
def quality2 = puts "done"
```

`all_commands.keys` is the list of every task name defined so far, as strings. The block above returns `[[:a_check, :b_check, :c_check]]`: an array with one element, an array of three tasks, which is one parallel stage, exactly like writing `depends_on [:a_check, :b_check, :c_check]`.

### The Shape of the Result

The block must return an Array of stages. Each stage is a Symbol or String (a sequential task) or an Array of Symbols or Strings (a parallel group). Nothing nests deeper than that. A mixed pipeline is written the same way the plain form is:

```ruby
depends_on { [:setup, %i[a_check b_check], :teardown] }
desc "setup, then a_check and b_check in parallel, then teardown"
def full_cycle = puts "full_cycle: done"
```

Use braces for a one-line block and `do ... end` when the block has several statements. Either way the last expression is the result:

```ruby
depends_on do
  all_checks  = all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)
  slow_checks = %i[integration_check]

  [:setup, all_checks - slow_checks, :teardown]
end
desc "Every check except the slow ones"
def smoke = puts "smoke: done"
```

The shape is checked as soon as the block returns. A wrong shape stops asgard with a message naming the task and the offending value, instead of failing later with an obscure error. The common mistake is one pair of brackets too many:

```ruby
depends_on { [[all_commands.keys.grep(/_check\z/).map(&:to_sym)]] }   # one [ ] too many
```

```
asgard: depends_on proc/block for 'quality' returned invalid dependency [:a_check, :b_check, :c_check] (Array) in a parallel group; expected a Symbol or String
```

Other shape errors read the same way, for example `returned invalid stage 123 (Integer); expected a Symbol, String, or Array of them`. If the block itself raises, asgard reports that too: `asgard: depends_on proc for 'quality' raised RuntimeError: boom`.

### What the Block Can See

The block is written in the `Tasks` class body, so inside it `self` is that class: `all_commands` and the other class-level words work bare, with no prefix, even though the block is not called until later. Once it resolves, the result replaces the block, so cycle detection, the undefined-task check and the arguments check all run against the resolved list, exactly as for a plain one.

`depends_on` takes a list or a block, never both; combining them is an error.

!!! warning
    The block runs before the command line is parsed, so `options`, `verbose?` and `debug?` inside it always see their defaults, never what was typed on this run. Keep the block to shaping the dependency list.

!!! tip
    Reach for the block only when the list cannot be known until every file has loaded. A fixed list is clearer written out. `examples/depends_on_block/good/.loki` and `bad/.loki` in the repository are two small projects showing the block form working and the shape error; see [Examples](examples.md).

---

## Dependencies Inside Subcommands

`depends_on` works inside a subcommand class exactly as at the top level. It names that class's own tasks:

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

Each subcommand class has its own dependency graph, validated at startup like the top-level one. See [Subcommands](subcommands.md).

---

## Summary

| Form | Meaning |
|---|---|
| `depends_on :a` | Run `a` first |
| `depends_on :a, :b` | Run `a`, then `b` |
| `depends_on [:a, :b]` | Run `a` and `b` at the same time |
| `depends_on :a, [:b, :c], :d` | `a`, then `b` with `c`, then `d` |
| `depends_on { [...] }` or `depends_on -> { [...] }` | Compute the list after every file has loaded |
| `dep_result(:a)` | In the task body: what `a` returned |
| `dep_results` | In the task body: every direct dependency's result, by name |

Every task runs once per `asgard` command. A failing command or a raised error stops the run; a return value does not.
