# Getting Started

This guide walks you through installing Asgard, creating your first `.loki` task file, and running tasks from the command line.

---

## Installation

=== "RubyGems"

    ```bash
    gem install asgard
    ```

=== "Bundler"

    ```bash
    bundle add asgard
    ```

    Or add it manually to your `Gemfile`:

    ```ruby
    gem "asgard", "~> 0.1"
    ```

    then run `bundle install`.

---

## Verify the Installation

```bash
asgard --version
# 0.1.2
```

---

## Create Your First Task File

Every Asgard project needs a `.loki` file at its root. This hidden file is both the project root marker (Asgard searches upward from CWD to find it) and the entry point for your tasks.

```bash
# Create the root marker in your project directory
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
    The `Tasks` class is pre-defined by the gem as `class Tasks < Asgard::Base`. You just reopen it — no `require` or superclass declaration needed.

---

## Run Your Task

```bash
asgard hello
# Hello, World!
```

See all available tasks:

```bash
asgard help
```

See help for a specific task:

```bash
asgard help hello
```

---

## Add a Parameter

Positional parameters are declared directly in the method signature. Document them in the `desc` usage string:

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
# Hello, World!

asgard greet Alice
# Hello, Alice!
```

---

## Add an Option

Use `method_option` (alias: `option`) to declare named flags:

```ruby
class Tasks
  desc "greet NAME", "Greet someone by name"
  option :shout, aliases: "-s", type: :boolean, desc: "Uppercase the greeting"
  def greet(name = "World")
    msg = options[:shout] ? "HELLO, #{name.upcase}!" : "Hello, #{name}!"
    puts msg
  end
end
```

```bash
asgard greet Alice --shout
# HELLO, ALICE!
```

---

## Multi-Loki Structure

A large Asgard project might look like this:

```
myproject/
  .loki          ← root marker and entry point (may be empty or contain tasks)
  build.loki     ← build-related and library dependency-related tasks
  deploy.loki    ← deployment tasks
  qa.loki        ← test and lint tasks
```

Each `*.loki` file reopens `class Tasks`. To load them, pass `--auto-load` to the `asgard` command — they are loaded alphabetically before `.loki`. See [Task Files](task-files.md) for full details.

---

## Built-in Flags

Every task automatically has three flags available, defined as `class_option` on `Tasks`:

| Flag | Description |
|---|---|
| `--version` | Print the Asgard version and exit |
| `--debug` | Set `$DEBUG = true` before the task runs |
| `--verbose` | Set `$VERBOSE = true` before the task runs |

```bash
asgard --version
asgard hello --debug
asgard hello --verbose
```

Inside a task body, use the `debug?` and `verbose?` predicates:

```ruby
def hello
  puts "building..."
  sh "make --debug" if debug?
end
```

---

## Next Steps

- [Defining Tasks](tasks.md) — parameters, options, aliases, long_desc
- [Dependencies](dependencies.md) — sequential, parallel, and mixed dependency graphs
- [Variables](variables.md) — share values across tasks
- [Shell Helpers](shell.md) — `sh`, `shebang`, and polyglot scripts
- [Subcommands](subcommands.md) — group related tasks under a namespace
- [Examples](examples.md) — working `.loki` files for every feature
