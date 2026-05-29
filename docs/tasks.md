# Defining Tasks

Every task is a public method inside `class Tasks`. Asgard pre-defines `Tasks` as a subclass of `Asgard::Base` (which is itself a Thor subclass), so your `.loki` files just reopen the class and add methods. The full Thor DSL is available everywhere.

---

## Basic Task

A task with no parameters and no options:

```ruby
class Tasks
  desc "hello", "Say hello"
  def hello = sh 'echo "Hello, World!"'
end
```

`desc` takes two arguments: the usage string and the one-line description shown in `asgard help`.

```bash
asgard hello
```

---

## Positional Parameter with Default

Positional parameters are declared directly in the method signature. Document them in the `desc` usage string (uppercase by convention):

```ruby
class Tasks
  desc "greet NAME", "Greet NAME; omit NAME to greet the world"
  def greet(name = "World")
    sh "echo 'Hello, #{name}!'"
  end
end
```

```bash
asgard greet           # Hello, World!
asgard greet Alice     # Hello, Alice!
```

---

## Named Options

Use `method_option` (alias: `option`) for named flags. Access them inside the method via `options[:name]`.

### All Five Option Types

```ruby
class Tasks
  desc "compile", "Compile the project"
  option :output,  aliases: "-o", type: :string,  default: "dist/",  desc: "Output directory"
  option :verbose, aliases: "-v", type: :boolean, default: false,    desc: "Enable verbose output"
  option :jobs,    aliases: "-j", type: :numeric, default: 1,        desc: "Number of parallel jobs"
  option :tags,                   type: :array,                       desc: "Build tags to apply"
  option :defines,                type: :hash,                        desc: "Preprocessor defines (KEY:VALUE)"
  def compile
    puts "Compiling → #{options[:output]} with #{options[:jobs]} job(s)"
    puts "Tags: #{options[:tags].join(', ')}" if options[:tags]
    puts "Defines: #{options[:defines]}"      if options[:defines]
  end
end
```

### Option Types Reference

| Type | CLI Example | Ruby Value |
|---|---|---|
| `:string` | `--output dist/` | `"dist/"` |
| `:boolean` | `--verbose` / `--no-verbose` | `true` / `false` |
| `:numeric` | `--jobs 4` | `4` |
| `:array` | `--tags foo bar baz` | `["foo", "bar", "baz"]` |
| `:hash` | `--defines KEY:val FOO:bar` | `{"KEY"=>"val", "FOO"=>"bar"}` |

### Common Option Keys

| Key | Description |
|---|---|
| `aliases` | Short-form flag, e.g. `"-o"` |
| `type` | `:string`, `:boolean`, `:numeric`, `:array`, or `:hash` |
| `default` | Value used when the flag is omitted |
| `required` | If `true`, Thor raises an error when the flag is missing |
| `desc` | One-line description shown in help |
| `enum` | Array of allowed values; Thor validates automatically |
| `banner` | Placeholder shown in help for the value slot, e.g. `"SECONDS"` |

---

## Required Option

```ruby
class Tasks
  desc "deploy ENV", "Deploy to ENV"
  option :strategy,
         type:     :string,
         required: true,
         enum:     %w[blue-green rolling canary],
         desc:     "Deployment strategy"
  def deploy(env = "staging")
    sh "cap #{env} deploy --strategy #{options[:strategy]}"
  end
end
```

```bash
asgard deploy          # Error: required option '--strategy' is missing
asgard deploy --strategy rolling
asgard deploy production --strategy blue-green
```

---

## Enum Validation

```ruby
class Tasks
  desc "build", "Build the project"
  option :env,
         type:    :string,
         default: "development",
         enum:    %w[development staging production],
         desc:    "Target environment"
  def build
    sh "rake build ENV=#{options[:env]}"
  end
end
```

Thor validates the value against the enum and shows a helpful error if it doesn't match.

---

## Banner

`banner` replaces the default `VALUE` placeholder in help output with a more descriptive name:

```ruby
class Tasks
  desc "wait", "Wait for a service to become available"
  option :timeout, type: :numeric, default: 30, banner: "SECONDS", desc: "Give up after SECONDS"
  def wait
    sh "wait-for-it --timeout #{options[:timeout]}"
  end
end
```

Help output shows: `[--timeout=SECONDS]` instead of `[--timeout=VALUE]`.

---

## Extended Description

`long_desc` provides detailed help shown by `asgard help <task>`. Use `\x5` at the start of a line to force a line break within the wrapped text (a Thor convention):

```ruby
class Tasks
  long_desc <<~DESC
    Generates a project report covering test coverage, lint results,
    and a dependency audit.

    Pass --format to control output style. Use --since to scope the
    report to changes after a given date.

    Examples:\x5
      asgard report --format html --since 2024-01-01\x5
      asgard report --format json --output report.json\x5
      asgard report --format text
  DESC
  desc "report", "Generate a project report"
  option :format, type: :string, default: "text", enum: %w[text html json], desc: "Output format"
  option :since,  type: :string, banner: "DATE",                            desc: "Limit to changes after DATE"
  def report
    sh "generate-report --format #{options[:format]}"
  end
end
```

!!! tip
    `desc` and `depends_on` are independent of each other — either can come first, but both must appear before the `def`.

---

## Default Task

`default_task` declares which command runs when `asgard` is invoked with no arguments:

```ruby
class Tasks
  default_task :greet

  desc "greet", "Say hello (runs by default)"
  def greet
    puts "Hello from Asgard!"
  end
end
```

```bash
asgard        # same as: asgard greet
```

---

## Command Aliases

`map` creates short aliases for existing tasks:

```ruby
class Tasks
  map "-v"  => "version"
  map "--v" => "version"
  map "t"   => "test"
  map "b"   => "build"

  desc "version", "Print the version"
  def version = puts Asgard::VERSION

  desc "test", "Run tests"
  def test = sh "bundle exec rake test"

  desc "build", "Build the gem"
  def build = sh "bundle exec rake build"
end
```

```bash
asgard t      # same as: asgard test
asgard b      # same as: asgard build
asgard -v     # same as: asgard version (note: --version is the built-in flag)
```

---

## Formal Argument Declaration

`argument` provides rich positional-parameter metadata including type checking, enums, and help text.

!!! warning "Class-level scope"
    `argument` is a **class-level declaration** that applies to **every task in the class**, not just the one that follows it. It is best suited for single-command CLIs or when every task in the file genuinely shares the same positional input. In multi-task files, prefer method signature parameters instead.

```ruby
class Tasks
  argument :name,
           type:    :string,
           default: "World",
           desc:    "Name to greet"

  desc "hello NAME", "Say hello to NAME"
  def hello = sh "echo 'Hello, #{name}!'"
end
```

For most multi-task `.loki` files, the simpler positional default pattern is safer:

```ruby
def hello(name = "World") = sh "echo 'Hello, #{name}!'"
```

---

## No Commands Block

`no_commands` marks a block of methods as public helpers that are excluded from the CLI and `--help` output. They are callable from any task in the same class:

```ruby
class Tasks
  desc "build", "Compile the project"
  def build
    puts "Revision: #{current_sha}"
    sh "rake build"
  end

  no_commands do
    def current_sha
      `git rev-parse --short HEAD`.strip
    end
  end
end
```

See [Helper Methods](helpers.md) for the full guide on helpers, `private`, and cross-file sharing.
