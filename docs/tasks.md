# Defining Tasks

A task is a public method inside `class Tasks` with a `desc` line above it. That is the whole rule. This page starts there and then adds, one step at a time, everything a task can have: parameters, typed options, extended help, hidden tasks, a default, short aliases, and control over the exit status. Asgard is built on Thor, so Thor's own words (`desc`, `method_option`, `long_desc`, `map`, `default_task`, `argument`) are the ones you write.

---

## Basic Task

```ruby
class Tasks
  desc "Say hello"
  def hello = puts "Hello, World!"
end
```

```bash
asgard hello
```

```
Hello, World!
```

The method body can be any Ruby. A one-line method reads well with the `def name = expression` form; a longer one uses the usual `def ... end`.

---

## Describing a Task: `desc`

`desc` takes one or two strings.

With one, it is the description shown by `asgard help`, and the usage line is the method name:

```ruby
desc "Run the test suite"
def test = sh "bundle exec rake test"
```

```
asgard test  # Run the test suite
```

With two, the first is the usage line and the second the description. Use the two-argument form whenever the task takes something after its name, so the help says so:

```ruby
desc "greet NAME", "Greet NAME by name"
def greet(name = "World") = puts "Hello, #{name}!"
```

```
asgard greet NAME  # Greet NAME by name
```

`desc` goes directly above the `def`. `depends_on` (see [Dependencies](dependencies.md)) goes above the `def` too, in either order with `desc`.

The description is one line, shown in the command list. For a longer explanation that `asgard help TASK` prints under the usage and options, add `long_desc`; see [Extended Help: `long_desc`](#extended-help-long_desc) below. To describe a task but keep it out of the list, add `hide: true`; see [Hidden Tasks](#hidden-tasks).

---

## Positional Parameters

A task's positional parameters are its method's parameters. Give each a default so the task also runs with nothing after its name:

```ruby
class Tasks
  desc "greet NAME", "Greet NAME; omit NAME to greet the world"
  def greet(name = "World")
    puts "Hello, #{name}!"
  end

  desc "copy FROM TO", "Copy FROM to TO"
  def copy(from, to) = sh "cp #{from} #{to}"
end
```

```bash
asgard greet            # Hello, World!
asgard greet Alice      # Hello, Alice!
asgard copy a.txt b.txt
asgard copy a.txt
```

```
ERROR: "asgard copy" was called with arguments ["a.txt"]
Usage: "asgard copy FROM TO"
```

A missing required parameter is a usage error: the message prints and asgard exits 1.

!!! warning "Dependencies cannot take required parameters"
    A task that another task lists in `depends_on` is run with no arguments. If it has a required parameter, asgard refuses at startup: `asgard: task 'copy' has 2 required argument(s) and cannot be used as a dependency`. Give the parameter a default, or read the value from an option or an environment variable instead.

A splat collects everything that follows:

```ruby
desc "lint FILES...", "Lint the given files (default: lib)"
def lint(*files)
  files = ["lib"] if files.empty?
  sh "rubocop #{files.join(' ')}"
end
```

---

## Named Options

`option` (or its longer name `method_option`) declares a flag for the task that follows it. Inside the task, `options.name` or `options[:name]` holds the value, and a boolean reads as `options.name?`.

```ruby
class Tasks
  desc "Compile the project"
  option :output,  aliases: "-o", type: :string,  default: "dist/", desc: "Output directory"
  option :verbose, aliases: "-v", type: :boolean, default: false,   desc: "Enable verbose output"
  option :jobs,    aliases: "-j", type: :numeric, default: 1,       desc: "Number of parallel jobs"
  option :tags,                   type: :array,                     desc: "Build tags to apply"
  option :defines,                type: :hash,                      desc: "Preprocessor defines (KEY:VALUE)"
  def compile
    puts "Compiling into #{options.output} with #{options.jobs} job(s)"
    puts "Tags: #{options.tags.join(', ')}" if options.tags
    puts "Defines: #{options.defines}"      if options.defines
    puts "(verbose)"                        if options.verbose?
  end
end
```

```bash
asgard compile -o build/ -j 4 --tags debug release --defines VERSION:2 MODE:fast
```

```
Compiling into build/ with 4 job(s)
Tags: debug, release
Defines: {"VERSION" => "2", "MODE" => "fast"}
```

### Reading an Option

`options` answers three spellings, all the same value:

| Spelling | Returns |
|---|---|
| `options.jobs` | The value, or `nil` when the option was not given and has no default |
| `options[:jobs]` | The same; a string key, `options["jobs"]`, works too |
| `options.verbose?` | `true` or `false`, never `nil`; the natural form for a boolean |

A predicate with an argument compares: `options.format?("md")` is `options[:format] == "md"`.

### The Five Option Types

| Type | On the command line | Value in the task |
|---|---|---|
| `:string` | `--output dist/` or `--output=dist/` | `"dist/"` |
| `:boolean` | `--verbose` / `--no-verbose` | `true` / `false` |
| `:numeric` | `--jobs 4` | `4` |
| `:array` | `--tags foo bar baz` | `["foo", "bar", "baz"]` |
| `:hash` | `--defines KEY:val FOO:bar` | `{"KEY" => "val", "FOO" => "bar"}` |

An option with no `type:` is a string. Every boolean also accepts its `--no-` form, and `--skip-name` means the same as `--no-name`.

### Option Keys

| Key | Meaning |
|---|---|
| `aliases` | A short form, `"-o"`, or several, `%w[-o --out]` |
| `type` | One of the five types above |
| `default` | The value when the flag is not given |
| `required` | `true` makes omitting the flag a usage error |
| `desc` | The one-line description shown in help |
| `enum` | The allowed values; anything else is a usage error |
| `banner` | The placeholder shown in help for the value, instead of the type name |

### A Required Option

```ruby
class Tasks
  desc "deploy ENV", "Deploy to ENV"
  option :strategy, type: :string, required: true, enum: %w[blue-green rolling canary], desc: "Deployment strategy"
  def deploy(env = "staging")
    sh "cap #{env} deploy --strategy #{options[:strategy]}"
  end
end
```

```bash
asgard deploy
```

```
No value provided for required options '--strategy'
```

```bash
asgard deploy --strategy rolling
asgard deploy production --strategy blue-green
```

### Validating with `enum`

```ruby
class Tasks
  desc "Build the project"
  option :env, type: :string, default: "development", enum: %w[development staging production], desc: "Target environment"
  def build = sh "rake build ENV=#{options[:env]}"
end
```

```bash
asgard build --env prod
```

```
Expected '--env' to be one of development, staging, production; got prod
```

### A Clearer Placeholder with `banner`

```ruby
class Tasks
  desc "Wait for a service to come up"
  option :timeout, type: :numeric, default: 30, banner: "SECONDS", desc: "Give up after SECONDS"
  def wait = sh "wait-for-it localhost:3000 --timeout #{options[:timeout]}"
end
```

`asgard help wait` shows `[--timeout=SECONDS]` instead of `[--timeout=N]`.

Options that every task should accept are declared once with `class_option`; see [Options & Flags](options.md).

---

## Extended Help: `long_desc`

`long_desc` adds a longer explanation that `asgard help <task>` prints after the usage and options. The text is re-wrapped to the terminal width; put `\x5` at the end of a line to force a line break there, which keeps example commands on their own lines:

```ruby
class Tasks
  long_desc <<~DESC
    Generates a project report covering test coverage, lint results,
    and a dependency audit.

    Pass --format to control the output style. Use --since to limit the
    report to changes after a given date.

    Examples:\x5
      asgard report --format html --since 2024-01-01\x5
      asgard report --format json --output report.json\x5
      asgard report --format text
  DESC
  desc "Generate a project report"
  option :format, type: :string, default: "text", enum: %w[text html json], desc: "Output format"
  option :since,  type: :string, banner: "DATE",                            desc: "Limit to changes after DATE"
  option :output, type: :string, banner: "FILE",                            desc: "Write the report to FILE"
  def report = sh "generate-report --format #{options[:format]}"
end
```

```bash
asgard help report
```

```
Usage:
  asgard report

Options:
  [--format=FORMAT]  # Output format
                     # Default: text
                     # Possible values: text, html, json
  [--since=DATE]     # Limit to changes after DATE
  [--output=FILE]    # Write the report to FILE
  ...

Description:
  Generates a project report covering test coverage, lint results, and a
  dependency audit.

  Pass --format to control the output style. Use --since to limit the report
  to changes after a given date.

  Examples:
    asgard report --format html --since 2024-01-01
    asgard report --format json --output report.json
    asgard report --format text
```

`long_desc`, `desc`, the options and `depends_on` can appear in any order; they all apply to the next `def`.

---

## Hidden Tasks

A hidden task runs from the command line and can be a dependency, but `asgard help` leaves it out. There are two ways to get one.

**Ask for it** with `hide: true`. Use this for a task that is part of the project's machinery and not something a person would type:

```ruby
class Tasks
  desc "Ask before running the task that depends on this", hide: true
  def confirm
    answer = ask("Really run `asgard #{ARGV.join(' ')}`? [y/N]")
    raise Asgard::Error, "aborted" unless answer.strip.downcase.start_with?("y")
  end

  depends_on :confirm
  desc "Drop and recreate the database"
  def reset_database = sh "bin/rails db:reset"
end
```

`asgard help` shows `reset_database` but not `confirm`; `asgard confirm` still works.

**Leave out the `desc`.** A public method with no `desc` is also a hidden task:

```ruby
class Tasks
  def current_sha = `git rev-parse --short HEAD`.strip   # a hidden task, by accident
end
```

```bash
asgard current_sha      # runs, prints nothing, exits 0
```

!!! warning "Helpers must not be public methods"
    This catches people who write helper methods as plain `def`s. Every public method is a task: `asgard current_sha` runs it, `depends_on :current_sha` accepts it, and `asgard --doctor` lists it as `hidden (no desc; not shown by help)`. Make helpers `private`, put them inside `no_commands do ... end`, or define them with `helper`. All three are on [Helper Methods](helpers.md).

---

## Default Task

`default_task` names the task that runs when you type `asgard` with nothing after it:

```ruby
class Tasks
  default_task :greet

  desc "Say hello (runs by default)"
  def greet = puts "Hello from Asgard!"
end
```

```bash
asgard            # same as: asgard greet
```

Without `default_task`, a bare `asgard` prints the help.

Only one default can win. When a second file sets another, asgard warns on standard error and the last one loaded is used:

```
asgard: default_task :deploy at /proj/deploy.loki:3 overrides default_task :greet set at /proj/.loki:2
```

---

## Abbreviated Command Matching

Every task is a Thor command, and Thor resolves any unambiguous prefix of a command name to that command automatically. Nothing to declare. Given:

```ruby
class Tasks
  desc "Check code style with RuboCop"
  def rubocop_check = sh "bundle exec rubocop"

  desc "Run the test suite"
  def test_check = sh "bundle exec rake test"

  desc "Run the test suite with verbose output"
  def test_verbose = sh "bundle exec rake test -v"

  desc "Deploy to production"
  def deploy = sh "cap production deploy"

  desc "Deploy to staging"
  def deploy_staging = sh "cap staging deploy"
end
```

```bash
asgard r             # same as: asgard rubocop_check, the only task starting with "r"
asgard test_c        # same as: asgard test_check, enough of the name to be unique
asgard test          # Ambiguous command test matches [test_check, test_verbose]
asgard deploy        # runs deploy, not deploy_staging; see below
```

Matching is on a plain prefix, so the shortest string that is still unique among your tasks works. Two details worth knowing:

- **An exact full name always wins**, even if it is also a prefix of another task. `asgard deploy` runs `deploy` itself, never the ambiguous-prefix error, because `deploy` is a defined command and not merely a prefix of `deploy_staging`.
- **An ambiguous prefix produces a clean error listing every candidate** (`Ambiguous command X matches [...]`) rather than guessing or running the first match. Type enough of the name to disambiguate.

!!! tip
    Because matching depends on every task name currently defined, a short prefix that is unique today can become ambiguous tomorrow when a new task with the same stem is added. Adding `rubocop_fix` alongside `rubocop_check` turns `asgard r` from a clean match into `Ambiguous command r matches [rubocop_check, rubocop_fix]`. Use [`map`](#command-aliases) for a short name that must stay stable.

---

## Command Aliases

`map` gives a task another name. Several aliases can point at one task:

```ruby
class Tasks
  map "t"   => "test"
  map "b"   => "build"
  map "-v"  => "version"

  desc "Print the project version"
  def version = puts "1.4.0"

  desc "Run tests"
  def test = sh "bundle exec rake test"

  desc "Build the gem"
  def build = sh "gem build myapp.gemspec"
end
```

```bash
asgard t       # same as: asgard test
asgard b       # same as: asgard build
asgard -v      # same as: asgard version (asgard's own flag is --version)
```

An alias does not appear in `asgard help`; the task it points at does.

---

## Return Values and Exit Status

What a task returns decides asgard's exit status, which is what a shell script or CI job sees.

| The task | Exit status |
|---|---|
| Returns `:fail` | 1 |
| Returns anything else (`nil`, `true`, `:warn`, `:skip`, a string) | 0 |
| Raises `Asgard::Error, "message"` | 1, after printing `asgard: message` |
| Runs an `sh` command that fails | The command's exit status; asgard stops at that command |
| Calls `abort "message"` | 1, after printing the message |

The `:fail` convention suits a check that reports its own result and should not stop other work:

```ruby
class Tasks
  desc "Check code style with RuboCop"
  def rubocop_check
    output = `bundle exec rubocop 2>&1`
    File.write("rubocop_output.txt", output)
    puts "RuboCop: #{output.lines.find { |l| l.include?('files inspected') }&.strip} (see rubocop_output.txt)"
    $?.success? ? :pass : :fail
  end
end
```

```bash
asgard rubocop_check; echo "exit: $?"
```

```
RuboCop: 12 files inspected, 3 offenses detected (see rubocop_output.txt)
exit: 1
```

`raise Asgard::Error` is for a task that must stop everything with a message and no backtrace:

```ruby
desc "Release the gem"
def release
  raise Asgard::Error, "working tree is not clean" unless `git status --porcelain`.empty?
  sh "gem push pkg/myapp.gem"
end
```

```
asgard: working tree is not clean
```

!!! note
    A dependency's return value never stops the task that depends on it: if `rubocop_check` returns `:fail` as a dependency of `build`, `build` still runs. To stop a chain, raise `Asgard::Error` or let a failing `sh` exit. How dependencies report failure is covered on [Dependencies](dependencies.md#when-a-dependency-fails).

---

## Reserved Names

Some names belong to the machinery that runs your tasks, and a task or helper by one of them would break every command. Asgard refuses them when the `.loki` loads, naming the file and line:

```ruby
class Tasks
  desc "Run everything"
  def run = sh "make all"
end
```

```
asgard: 'run' at /proj/.loki:3 is a name Thor reserves and cannot be a task or helper; rename it
```

The reserved names are the ones Thor uses internally, among them `run`, `shell`, `options`, `invoke`, `args`, `action`, `behavior`, `root`, `inside`, `in_root`, `create_file`, `add_file` and `run_ruby_script`. Pick another word (`run_all`, `start`) or put the task in a [subcommand](subcommands.md).

Names starting with `_` are asgard's own. Asgard's built-in commands use them, and `asgard _anything` is refused with `asgard: unknown command '_anything'`. Do not start a task or helper name with an underscore.

---

## Formal Argument Declaration

`argument` declares a positional parameter with metadata: a type, a default, allowed values and a description that shows in help.

!!! warning "Class-level scope"
    `argument` applies to **every task in the class**, not just the one that follows it. It suits a single-command tool, or a class whose tasks all take the same first value. In a `.loki` with many tasks, use method parameters instead.

```ruby
class Tasks
  argument :name, type: :string, default: "World", desc: "Name to greet"

  desc "hello NAME", "Say hello to NAME"
  def hello = puts "Hello, #{name}!"
end
```

For a multi-task file, the same thing as a method parameter:

```ruby
def hello(name = "World") = puts "Hello, #{name}!"
```

---

## Running Several Tasks in One Command

`asgard` runs one task per invocation, plus its dependencies. The `do` task in the repository's examples adds the `asgard do lint test build` style on top, as an ordinary task you can copy into your own `.loki`; steps can carry their own arguments when separated by commas. See [Examples](examples.md#doloki).

---

## Helpers

Not every method should be a task. `private` methods, `no_commands` blocks and the `helper` DSL all define methods your tasks can call that never show up as commands. They are covered on [Helper Methods](helpers.md).
