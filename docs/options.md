# Options & Flags

Asgard tasks use the full Thor option system. Options declared with `method_option` (alias: `option`) apply to a single task. Options declared with `class_option` apply to every task in the class. Asgard ships with three built-in `class_option` declarations on `Tasks`: `--debug`, `--verbose`, and `--version`.

---

## Per-Task Options

`method_option` (or its alias `option`) declares an option for the immediately following task:

```ruby
class Tasks
  desc "deploy ENV", "Deploy to ENV"
  method_option :branch,
                aliases: "-b",
                type:    :string,
                default: "main",
                desc:    "Git branch to deploy"
  method_option :dry_run,
                aliases: "-n",
                type:    :boolean,
                default: false,
                desc:    "Print commands without running"
  def deploy(env = "staging")
    if options[:dry_run]
      puts "Would deploy #{options[:branch]} to #{env}"
    else
      sh "cap #{env} deploy BRANCH=#{options[:branch]}"
    end
  end
end
```

Access option values inside the task body via `options[:name]` (a hash keyed by symbol).

---

## Class Options (Shared Across All Tasks)

`class_option` defines an option available on every task in the class. Add your own to complement the built-in ones:

```ruby
class Tasks
  class_option :dry_run,
               aliases: "-n",
               type:    :boolean,
               default: false,
               desc:    "Print commands without running"

  class_option :env,
               type:    :string,
               default: "development",
               enum:    %w[development staging production],
               desc:    "Target environment"

  desc "deploy", "Deploy the application"
  def deploy
    if options[:dry_run]
      puts "Would deploy to #{options[:env]}"
    else
      sh "cap #{options[:env]} deploy"
    end
  end

  desc "migrate", "Run database migrations"
  def migrate
    sh "rails db:migrate RAILS_ENV=#{options[:env]}"
  end
end
```

Both `deploy` and `migrate` automatically accept `--dry-run` and `--env`.

---

## Built-in Flags

`Tasks` ships with three built-in class options and a version flag:

### `--version`

Prints `Asgard::VERSION` and exits. Implemented as the `_version` method with the `_` prefix convention (gem-owned, blocked from direct CLI invocation):

```bash
asgard --version
# 0.1.2
```

### `--debug`

A `class_option :debug` of type `:boolean`. When passed, sets `$DEBUG = true` before the task body runs (via the `invoke_command` hook in `Asgard::Base`):

```bash
asgard build --debug
```

Inside the task, use the `debug?` predicate:

```ruby
def build
  sh "rake build"
  sh "rake build --trace" if debug?
end
```

### `--verbose`

A `class_option :verbose` of type `:boolean`. When passed, sets `$VERBOSE = true` before the task body runs:

```bash
asgard test --verbose
```

Inside the task, use the `verbose?` predicate:

```ruby
def test
  flags = verbose? ? "--verbose" : ""
  sh "bundle exec rake test #{flags}"
end
```

---

## `debug?` and `verbose?` Predicates

Both are private methods on `Tasks`, thin wrappers around the global variables:

```ruby
private

def debug?   = $DEBUG
def verbose? = $VERBOSE
```

They are available in every task body and in subcommand classes that inherit from `Tasks`. Because `--debug` and `--verbose` are `class_option` declarations (not standalone commands), they work as modifiers alongside any task:

```bash
asgard build --debug --verbose
asgard deploy production --verbose
```

---

## Option Types Reference

| Type | CLI Example | Ruby Value |
|---|---|---|
| `:string` | `--branch main` | `"main"` |
| `:boolean` | `--force` / `--no-force` | `true` / `false` |
| `:numeric` | `--count 3` | `3` |
| `:array` | `--tags foo bar baz` | `["foo", "bar", "baz"]` |
| `:hash` | `--vars KEY:val FOO:bar` | `{"KEY"=>"val", "FOO"=>"bar"}` |

---

## Option Keys Reference

| Key | Applies to | Description |
|---|---|---|
| `aliases` | `method_option`, `class_option` | Short-form flag string, e.g. `"-b"` |
| `type` | `method_option`, `class_option` | One of the five types above |
| `default` | `method_option`, `class_option` | Value used when the flag is omitted |
| `required` | `method_option` | Raises an error if the flag is missing |
| `desc` | `method_option`, `class_option` | One-line description shown in help |
| `enum` | `method_option`, `class_option` | Allowed values; validated by Thor |
| `banner` | `method_option` | Placeholder shown in help for the value slot |

---

## `_` Prefix Convention

Methods whose names start with `_` are considered gem-owned in Asgard's naming convention. `run!` guards against invoking them directly from the CLI:

```bash
asgard _version
# asgard: unknown command '_version'
```

If you define your own methods on `Tasks`, avoid the `_` prefix to prevent them from being silently blocked.
