# Options & Flags

Options are the `--name value` and `--flag` words after a task name. A task declares its own with `option`; a class declares options that every task accepts with `class_option`; and asgard adds four flags of its own to every task: `--version`, `--doctor`, `--debug` and `--verbose`. This page covers all three layers, where `options[...]` can be read, and the reference tables for option types and keys.

---

## Per-Task Options

`option` (the long name is `method_option`) declares a flag for the task that follows it. The value is in `options[:name]` inside the task:

```ruby
class Tasks
  desc "deploy ENV", "Deploy to ENV"
  option :branch,  aliases: "-b", type: :string,  default: "main", desc: "Git branch to deploy"
  option :dry_run, aliases: "-n", type: :boolean, default: false,  desc: "Print commands without running them"
  def deploy(env = "staging")
    if options.dry_run?
      puts "Would deploy #{options.branch} to #{env}"
    else
      sh "cap #{env} deploy BRANCH=#{options.branch}"
    end
  end
end
```

```bash
asgard deploy production -b release --dry-run
```

```
Would deploy release to production
```

`options` is a hash with symbol keys that also answers method calls: `options.branch` is `options[:branch]`, and a boolean reads as a predicate, `options.dry_run?`, which is always `true` or `false`. An option that was not given and has no default is `nil`, so `options[:tags]` is `nil` rather than an empty array. Both `--branch release` and `--branch=release` work; a multi-word option name is typed with a dash, `--dry-run`, and read with an underscore, `options[:dry_run]`.

The full set of types and keys is on [Defining Tasks](tasks.md#named-options) and in the tables at the end of this page.

---

## Class Options: Shared by Every Task

`class_option` declares an option once for every task in the class. A `--dry-run` or `--env` that applies to the whole project belongs here:

```ruby
class Tasks
  class_option :dry_run, aliases: "-n", type: :boolean, default: false, desc: "Print commands without running them"
  class_option :env,     type: :string, default: "development", enum: %w[development staging production], desc: "Target environment"

  desc "Deploy the application"
  def deploy
    if options.dry_run?
      puts "Would deploy to #{options.env}"
    else
      sh "cap #{options.env} deploy"
    end
  end

  desc "Run database migrations"
  def migrate = sh "rails db:migrate RAILS_ENV=#{options[:env]}"
end
```

```bash
asgard deploy --env staging --dry-run
asgard migrate --env production
asgard help migrate          # lists --dry-run and --env under Options
```

Options come after the task name, class options included: `asgard deploy --env staging` works, while `asgard --env staging deploy` does not run the task; it prints the help for `deploy` and exits 0. The two exceptions are `--version` and `--doctor`, which are asgard's own flags and come first.

### Class Options and Subcommands

A subcommand class written as `class DBCommands < Tasks` inherits every class option declared on `Tasks`, including asgard's own. Declare new ones in the subcommand class for options only its tasks need.

!!! warning
    Do not declare `class_option :debug` or `class_option :verbose` (or `:version`, `:doctor`) in a subcommand class. They are already inherited. A second declaration raises no error; it quietly replaces asgard's own option for that class, so the help loses its description and default and shows `[--debug], [--no-debug], [--skip-debug]` instead. See [Subcommands](subcommands.md).

### Boolean Class Options and `no_negate`

For every boolean class option, the help lists three spellings: `[--color]`, `[--no-color]` and `[--skip-color]`. When negating the option makes no sense, call `no_negate` after the declaration to show only the plain flag:

```ruby
class Tasks
  class_option :color, type: :boolean, default: true, desc: "Colorize output"
  no_negate :color
end
```

Help before:

```
[--color], [--no-color], [--skip-color]  # Colorize output
```

Help after:

```
[--color]                                # Colorize output
```

`no_negate` takes several names at once, `no_negate :color, :emoji`, and only changes the help text: `--no-color` still works if someone types it.

---

## Built-in Flags

Four flags are available on every task. They appear under `Options:` in `asgard help`.

| Flag | What it does | When it acts |
|---|---|---|
| `--version` | Prints asgard's version and exits | Before any task file loads; works with no project |
| `--doctor` | Prints a diagnosis of the project's task files and exits | Before the normal startup, so it works even when a `.loki` is broken |
| `--debug` | Sets `$DEBUG` to true, so `debug?` is true | Before the task body runs |
| `--verbose` | Sets `$VERBOSE` to true, so `verbose?` is true | Before the task body runs |

```bash
asgard --version
asgard --doctor
asgard build --debug
asgard build --verbose
asgard build --debug --verbose
```

!!! note "Where each flag goes"
    `--version` and `--doctor` come first, before any task name. After a task name they are the task's own arguments: `asgard mytask --version` runs `mytask` and passes `--version` to it, which lets a task of yours define its own `--version` option. `--debug` and `--verbose` are ordinary class options and go after the task name, like every other option.

### `--version`

```bash
asgard --version
```

```
0.6.0
```

### `--doctor`

```bash
asgard --doctor
```

Prints which `.loki` was used, what each `import` loaded, every task grouped by the file that defines it with a `file:line` an editor can jump to, any task defined twice (the earlier one is silently dead), hidden tasks, and any dependency problem. It runs even when the normal startup would abort on a broken file. The report is explained line by line on [Help & Diagnostics](diagnostics.md#the-doctor-report).

### `--debug` and `--verbose`

Both set a Ruby global before the task runs, and the predicates `debug?` and `verbose?` read it back. They are also ordinary class options, so `options.debug?` and `options.verbose?` work and are always `true` or `false`:

```ruby
class Tasks
  desc "Compile the project"
  def build
    puts "options: #{options.inspect}" if debug?
    sh "rake build#{' --trace' if verbose?}"
  end
end
```

```bash
asgard build --verbose
```

```
rake build --trace
...
```

The flags also trace an `import` that runs inside a task body. With `--verbose`, such an `import` prints each file it loads on standard error; add `--debug` to also see a file it skipped because it was already loaded, and an `import_up` that found nothing:

```bash
asgard build --verbose --debug
```

```
import: /home/you/myproject/extra.loki
import: skip /home/you/myproject/extra.loki (already loaded)
import_up: team_tasks.loki not found
```

The imports at the top of `.loki` run before the task name is read, so the flags cannot trace them. To see every file as it loads, run with Ruby's warning switch, `RUBYOPT=-w asgard build`, or use `asgard --doctor`; see [Task Files](task-files.md#tracing-imports).

`debug?` and `verbose?` work everywhere in a `.loki`: in task bodies, in helpers, and in the class body. Note that `--debug`, `--verbose` and a task's own options are parsed only once the task is chosen, which is why a `depends_on` block cannot see them (next section).

---

## Where `options` Is Available

`options` is the parsed command line of the task being run. It is available:

- inside the task body;
- inside a helper method called from the task body (`private` methods, `no_commands` methods, `helper` methods);
- inside a dependency's body. The whole run shares one command line, so a value you type (`asgard deploy --target x`) reaches every dependency that declares that option. An option the dependency declares but you did not type takes the dependency's own default, not the default of the task you typed. An option only the typed task declares is passed through to the dependency as the typed task sees it.

It is not available:

- in the class body, where `desc`, `option` and `@@` variables are declared, because no command line has been parsed yet;
- inside a `depends_on { ... }` block, which runs while the task files are being validated, before the command line is parsed (see [Dependencies](dependencies.md#dynamic-dependencies)).

For a value a task needs at class-load time, read an environment variable with `env` instead; see [Environment Variables](environment.md).

---

## Option Types Reference

| Type | On the command line | Value in the task |
|---|---|---|
| `:string` | `--branch main`, `--branch=main` | `"main"` |
| `:boolean` | `--force` / `--no-force` / `--skip-force` | `true` / `false` |
| `:numeric` | `--count 3` | `3` |
| `:array` | `--tags foo bar baz` | `["foo", "bar", "baz"]` |
| `:hash` | `--vars KEY:val FOO:bar` | `{"KEY" => "val", "FOO" => "bar"}` |

An option declared without `type:` is a string. A `:numeric` value that is not a number is a usage error.

---

## Option Keys Reference

| Key | Applies to | Meaning |
|---|---|---|
| `aliases` | `option`, `class_option` | A short form such as `"-b"`, or an array of alternatives |
| `type` | `option`, `class_option` | One of the five types above |
| `default` | `option`, `class_option` | The value when the flag is omitted |
| `required` | `option`, `class_option` | `true` makes omitting the flag a usage error |
| `desc` | `option`, `class_option` | The one-line description shown in help |
| `enum` | `option`, `class_option` | The allowed values; anything else is a usage error |
| `banner` | `option`, `class_option` | The placeholder shown for the value in help, `[--timeout=SECONDS]` |

A usage error (unknown option, missing required option, a value outside `enum`) prints one line and exits 1 without running the task.
