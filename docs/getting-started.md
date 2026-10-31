# Getting Started

This page takes you from nothing to a working project in a few minutes: install asgard, create a `.loki` file, define a task, run it, and add a parameter and an option. Each step is a complete, runnable example. The last section shows how a project grows past one file.

---

## Installation

=== "RubyGems"

    ```bash
    gem install asgard
    ```

    This installs the `asgard` command for your Ruby. The gem compiles one native extension, so a C++17 compiler must be present (Xcode's command-line tools on macOS, `build-essential` or the equivalent on Linux).

=== "Bundler"

    To pin the version a project uses, add it to the project's `Gemfile`:

    ```bash
    bundle add asgard
    ```

    Then run it through Bundler so the pinned version is the one that runs:

    ```bash
    bundle exec asgard hello
    ```

    The rest of this manual writes plain `asgard ...`; prefix `bundle exec` if you installed it this way.

Check the installation:

```bash
asgard --version
```

```
0.6.0
```

`--version` works anywhere, even in a directory with no project.

---

## Create Your First Task File

Every project has one file named `.loki` at its root. It does two jobs: it marks the project root, so you can run `asgard` from any subdirectory, and it holds (or loads) your tasks.

```bash
cd ~/work/myproject
touch .loki
```

Open `.loki` in your editor and add a task:

```ruby
class Tasks
  desc "Say hello to the world"
  def hello = puts "Hello, World!"
end
```

!!! note
    `Tasks` already exists when your file loads; asgard defines it. You reopen the class and add methods. There is nothing to `require` and no superclass to name.

---

## Run Your Task

```bash
asgard hello
```

```
Hello, World!
```

See every task the project defines:

```bash
asgard help
```

```
asgard v0.6.0 The Mighty Thor and Loki working for you

Commands:
  asgard hello                # Say hello to the world
  asgard help [COMMAND]       # Describe available commands or one specific command
  asgard jobs SUBCOMMAND      # List, stop and restart the background jobs started with `sh ..., background: true`
  asgard schedule SUBCOMMAND  # Manage schedules declared with `schedule :task, ...` (launchd on macOS, systemd on Linux)
  asgard tree                 # Print a tree of all available commands
  asgard watcher SUBCOMMAND   # Run and manage the file watcher declared with `watch :task, paths: ...`

Options:
  [--debug]    # Enable debug mode ($DEBUG = true)
               # Default: false
  [--verbose]  # Enable verbose output ($VERBOSE = true)
               # Default: false
  [--version]  # Show asgard version and exit
               # Default: false
  [--doctor]   # Diagnose .loki resolution, imports, and task definitions for the CWD, then exit
               # Default: false

Documentation ... https://madbomber.github.io/asgard
Github Repo ..... https://github.com/MadBomber/asgard
```

Your `hello` sits beside asgard's built-in commands: `help`, `tree`, and the three management commands `schedule`, `watcher` and `jobs`, which have their own pages later in this manual.

Help for one task:

```bash
asgard help hello
```

```
Usage:
  asgard hello

Options:
  [--debug]    # Enable debug mode ($DEBUG = true)
               # Default: false
  ...

Say hello to the world
```

---

## Add a Parameter

A positional parameter is a parameter of the method. Give it a default so the task also runs with nothing after its name, and name it in the first argument of `desc` so the help shows it:

```ruby
class Tasks
  desc "greet NAME", "Greet someone by name"
  def greet(name = "World")
    puts "Hello, #{name}!"
  end
end
```

```bash
asgard greet
asgard greet Alice
```

```
Hello, World!
Hello, Alice!
```

Without a default, the parameter is required and `asgard greet` prints a usage error and exits 1.

---

## Add an Option

`option` declares a named flag for the task that follows it. Inside the task, a boolean reads as `options.name?`; any option's value is `options.name` or `options[:name]`:

```ruby
class Tasks
  desc "greet NAME", "Greet someone by name"
  option :shout, aliases: "-s", type: :boolean, desc: "Uppercase the greeting"
  def greet(name = "World")
    message = "Hello, #{name}!"
    puts options.shout? ? message.upcase : message
  end
end
```

```bash
asgard greet Alice --shout
asgard greet Alice -s
```

```
HELLO, ALICE!
HELLO, ALICE!
```

`asgard help greet` now lists `--shout` with its description. Options can be strings, numbers, lists and more; see [Defining Tasks](tasks.md#named-options).

---

## Type Less

Any unambiguous prefix of a task name runs it:

```bash
asgard gre          # same as: asgard greet
asgard hel Bob      # Ambiguous command hel matches [hello, help]
asgard hello        # an exact name always wins
```

When a prefix matches more than one task, asgard lists the candidates instead of guessing. `map` gives a task a short name that stays stable; see [Command Aliases](tasks.md#command-aliases).

---

## Run a Shell Command

Most tasks run programs. `sh` runs a command, or a whole script, under the default shell (bash unless the project picks another) and prints it first:

```ruby
class Tasks
  desc "Show the Ruby version"
  def ruby_version = sh "ruby --version"

  desc "Install dependencies and run the tests"
  def check
    sh <<~SHELL
      bundle install --quiet
      bundle exec rake test
    SHELL
  end
end
```

```bash
asgard ruby_version
```

```
ruby --version
ruby 4.0.9 (2026-10-23 revision 3e93b23afc) +PRISM [arm64-darwin27]
```

When a command fails, asgard stops there and exits with the command's status, so a pipeline never silently continues past a broken step:

```bash
asgard check; echo "exit: $?"
```

```
bundle install --quiet
bundle exec rake test
...
rake aborted!
exit: 1
```

Ruby's own ways of running a program, `system`, backticks and the rest, work in a task too. `sh` and its sibling `shebang` add what a task runner needs around the command: the echo, the stop on failure with the right exit status, a pinned shell so the script behaves the same under the watcher and a schedule, and `background: true` for a process that outlives asgard. The comparison is in [`sh` Versus Ruby's Own Methods](shell.md#sh-versus-rubys-own-methods); Python, Node and other interpreters, and how to pick which bash runs, are on the same [Shell Commands](shell.md) page.

---

## Built-in Flags

Every task accepts four flags that belong to asgard itself:

| Flag | What it does |
|---|---|
| `--version` | Print asgard's version and exit, before any task file loads |
| `--doctor` | Print a diagnosis of the project's `.loki` files (what loaded, what each file defines, overridden tasks, dependency problems) and exit |
| `--debug` | Set `$DEBUG` before the task runs; `debug?` returns true inside the task |
| `--verbose` | Set `$VERBOSE` before the task runs; `verbose?` returns true inside the task |

```bash
asgard --version
asgard --doctor
asgard greet --debug
asgard greet --verbose Alice
```

!!! note
    `--version` and `--doctor` are asgard's own flags only when they come before the task name. After it, they belong to the task: `asgard greet --version` passes `--version` to `greet`.

Inside a task, `debug?` and `verbose?` let you add detail on request:

```ruby
class Tasks
  desc "Compile the project"
  def build
    puts "building with #{options.inspect}" if debug?
    sh verbose? ? "rake build --trace" : "rake build"
  end
end
```

The `--doctor` report is explained on [Help & Diagnostics](diagnostics.md).

---

## Growing the Project

One `.loki` is enough for a while. When it gets long, split tasks by concern into sibling files and have `.loki` load them:

```
myproject/
  .loki          ← root marker; loads the others
  build.loki     ← build tasks
  deploy.loki    ← deploy tasks
  qa.loki        ← test and lint tasks
```

```ruby
# .loki
import "*.loki"

class Tasks
  @@app ||= "myproject".freeze
end
```

```ruby
# qa.loki
class Tasks
  desc "Run the tests"
  def test = sh "bundle exec rake test"
end
```

Each `*.loki` file reopens the same `Tasks` class, so tasks in one file can depend on tasks in another, and a value set in `.loki` is visible everywhere. `import "*.loki"` loads the siblings in alphabetical order; `import "deploy.loki"` loads one by name. The rules are on [Task Files](task-files.md).

---

## Next Steps

- [Defining Tasks](tasks.md): parameters, every option type, extended help, hidden tasks, aliases
- [Dependencies](dependencies.md): run tasks before other tasks, in sequence or in parallel
- [Shell Commands](shell.md): `sh`, `shebang`, Python and Node scripts, choosing a shell
- [Variables](variables.md): share values between tasks and files
- [Subcommands](subcommands.md): group tasks as `asgard db migrate`
- [Scheduled Tasks](schedule.md), [Watched Files](watch.md), [Background Jobs](jobs.md): run tasks when you are not there
- [Examples](examples.md): complete `.loki` files for every feature
