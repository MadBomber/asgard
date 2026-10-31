# Variables

A `.loki` file is plain Ruby, so the values your tasks share, an application name, a port, a build directory, are plain Ruby variables. One kind of variable is the right one for a task file, and this page explains which and why, with enough Ruby for a reader who has never written any.

The short version: declare shared values as `@@name` at the top of `class Tasks`, with `||=` and `.freeze`:

```ruby
class Tasks
  @@app  ||= "myapp".freeze
  @@port ||= 3000

  desc "Print app info"
  def info = puts "#{@@app} on port #{@@port}"
end
```

```bash
asgard info
# myapp on port 3000
```

---

## Ruby Variable Kinds

Ruby has four kinds of variable plus constants, each with its own prefix and its own scope. Tasks are methods, so the wrong kind is simply invisible where you expect it:

| Kind | Prefix | Example | Visible in |
|------|--------|---------|------------|
| Local | none | `count = 0` | The method or block it is set in |
| Instance | `@` | `@sha = "abc"` | One object; inside a task, that task run |
| Class | `@@` | `@@app = "myapp"` | The class body, every task, every subcommand |
| Global | `$` | `$DEBUG = true` | The whole process |
| Constant | Capital letter | `APP = "myapp"` | Everywhere |

### Local Variables

A local variable lives in the method it is set in and disappears when the method returns:

```ruby
def build
  output_dir = "dist"            # only this method can see it
  sh "rake build OUTDIR=#{output_dir}"
end
```

No other task can see `output_dir`. Locals are for values a single task computes and uses.

### Instance Variables (`@`)

Inside a task, `@name` belongs to the object running that task. It is handy for caching a value within one run:

```ruby
def version
  @version ||= `git describe --tags`.strip   # computed once per run, then reused
end
```

In the class body, outside any method, `@name` sets a variable on the class itself, which is a different object from the one that runs tasks. So this does not work:

```ruby
class Tasks
  @app = "myapp"         # on the class, not on the task runner

  def build
    puts @app            # nil
  end
end
```

Two more cautions. An instance variable set by one task is visible to a later task in the same run only when they run one after another; tasks in a parallel `depends_on` group each get their own object, so pass values with `dep_result` instead (see [Dependencies](dependencies.md#passing-results-between-tasks)). And a value that should be shared belongs in `@@`, below.

### Class Variables (`@@`)

`@@name` is shared by the class body, every task method and every subclass, which includes [subcommand](subcommands.md) classes. That is exactly the set of places a task file's configuration needs to reach, so `@@` is the kind to use:

```ruby
class Tasks
  @@app = "myapp"        # visible in every task and every subcommand

  def build
    puts @@app           # "myapp"
  end
end
```

### Global Variables (`$`)

`$name` is visible everywhere in the process, including inside every gem asgard loads. Asgard itself uses two: `--debug` sets `$DEBUG` and `--verbose` sets `$VERBOSE`, which you read with `debug?` and `verbose?` (see [Options & Flags](options.md)). `$stdout` and `$stderr` are the output streams `puts` and `warn` write to. Avoid declaring your own globals; `@@` does the job without leaking into everything else.

### Constants

A name that starts with a capital letter is a constant. Constants are visible everywhere, with no prefix, inside and outside the class:

```ruby
APP_NAME = "myapp".freeze
BASE_URL = "https://example.com".freeze

class Tasks
  desc "Deploy the app"
  def deploy
    puts "Deploying #{APP_NAME} to #{BASE_URL}"
    sh "cap deploy"
  end
end
```

Ruby warns when a constant is assigned twice but does not prevent it, which matters when two `.loki` files both define `APP_NAME`. Use `.freeze` so the value itself cannot be changed.

| | Constant | `@@` class variable |
|---|---|---|
| Visible in tasks and subcommands | Yes | Yes |
| Visible outside `Tasks` | Yes | No |
| Second assignment | Warning | Silent (so use `\|\|=`) |
| Convention | `ALL_CAPS` | `snake_case` |

Constants suit values that never change: an application name, a URL, a port. `@@` with `||=` suits values a later file might want to set first or override.

---

## The Pattern

```ruby
class Tasks
  @@app  ||= "myapp".freeze
  @@port ||= 3000
  @@env  ||= "production".freeze
end
```

**Why `||=` and not `=`?** Every `.loki` file reopens the same `class Tasks`. With `||=`, the first file to set a value wins and a later file that reopens the class does not overwrite it. That lets a shared task library ship a default that a project's own `.loki` sets first.

**Why `.freeze`?** It makes the value itself unchangeable, so `@@app << "-extra"` raises an error instead of quietly altering a name every task uses. Numbers and symbols are already frozen; freeze strings, arrays and hashes.

**Why `@@` and not `@`?** A single `@` in the class body is not visible inside task methods, as shown above. `@@` is visible everywhere a task file needs.

---

## Strings and Interpolation

### Use Double Quotes

Ruby has single and double quoted strings. Task files use double quotes throughout, because only double quotes support interpolation, and shell commands almost always need a value embedded:

```ruby
@@app ||= "myapp".freeze
sh "bundle exec rake test"
```

### Interpolation

`#{...}` inside a double-quoted string inserts the value of any Ruby expression:

```ruby
class Tasks
  @@app ||= "myapp".freeze
  @@env ||= "production".freeze

  desc "Deploy the app"
  def deploy = sh "cap #{@@env} deploy APP=#{@@app}"
end
```

Any expression works, not just a variable name:

```ruby
puts "build started at #{Time.now}"
sh "puma -p #{env(:port, '3000').to_i + 1}"
sh "git tag #{@@app}-#{`git describe --tags`.strip}"
```

### Multi-line Scripts

For a script with several lines, use a heredoc. `<<~` strips the leading indentation so the script lines up with your Ruby, and interpolation works inside it:

```ruby
desc "Bootstrap the project"
def bootstrap
  sh <<~SHELL
    bundle install
    rails db:create db:migrate
    echo "#{@@app} ready on #{env(:port, '3000')}"
  SHELL
end
```

The word after `<<~` (here `SHELL`) is any marker you like; the heredoc ends at a line holding only that marker. See [Shell Commands](shell.md) for what happens when the script runs.

---

## Sharing Values Across Files

All `.loki` files reopen one `Tasks` class, so a `@@` variable set in one file is visible in every file loaded in the same run:

```ruby
# config.loki
class Tasks
  @@app  ||= "myapp".freeze
  @@port ||= 8080
end
```

```ruby
# deploy.loki
class Tasks
  desc "Deploy the app"
  def deploy = sh "cap deploy APP=#{@@app} PORT=#{@@port}"
end
```

The file that sets the value must load before the task that reads it *runs*, which is always true: every file loads before any task runs. Only the class body itself runs at load time, so a `header` line that interpolates `@@app` must come after the file that sets it has been imported. See [Task Files](task-files.md) for load order.

---

## Sharing Values With Subcommands

Subcommand classes inherit from `Tasks`, so they see its `@@` variables:

```ruby
# config.loki
class Tasks
  @@app ||= "myapp".freeze
end
```

```ruby
# deploy.loki
class DeployCommands < Tasks
  desc "Deploy to production"
  def production = sh "cap production deploy APP=#{@@app}"    # visible here
end

class Tasks
  desc "deploy SUBCOMMAND", "Deployment tasks"
  subcommand "deploy", DeployCommands
end
```

---

## Computed Values

A value that comes from a command, a file or any other runtime computation is a method, not a variable. Make it `private` so it is not a task:

```ruby
class Tasks
  desc "Show version info"
  def info = puts "#{version} (#{sha})"

  private

  def version = `git describe --tags`.strip
  def sha     = `git rev-parse --short HEAD`.strip
end
```

!!! warning
    A public method without a `desc` is a hidden task: it runs from the command line and can be a dependency, it is just left out of `asgard help`. Helpers must be `private`, inside a `no_commands` block, or defined with `helper`. See [Helper Methods](helpers.md).

Cache an expensive value with `@name ||=` inside the method, so it is computed once per run:

```ruby
def version
  @version ||= `git describe --tags`.strip
end
```

When the value is also needed in the class body, in a `header` line for instance, define it with `helper`, which makes it available in both places at once:

```ruby
class Tasks
  @@project ||= "myapp".freeze

  helper(:version) { File.read("lib/myapp/version.rb")[/VERSION\s*=\s*"([^"]+)"/, 1] }

  header "#{@@project} v#{version}"       # class body

  desc "Show the current version"
  def show_version = puts version          # task body
end
```

[Helper Methods](helpers.md#the-helper-dsl-method) has the details.

---

## Environment Variables

Values that come from outside the task file, from the shell, CI or a `.env` file, are read with `env`, which upcases the name and takes a default:

```ruby
class Tasks
  dotenv                                   # load .env, if there is one

  desc "Start the server"
  def start = sh "puma -p #{env(:port, '3000')}"     # "3000" when PORT is unset

  desc "Deploy the app"
  def deploy = sh "cap #{env(:deploy_target)} deploy"  # error when DEPLOY_TARGET is unset
end
```

Environment values are always strings; convert with `.to_i` or compare with `== "true"`. The whole story, including `dotenv`, `.env` files and the variables asgard itself sets, is on the [Environment Variables](environment.md) page.

---

## Naming

Class variables use `snake_case`, words separated by underscores:

```ruby
class Tasks
  @@app_name    ||= "myapp".freeze
  @@deploy_host ||= "production.example.com".freeze
  @@max_workers ||= 4
end
```

!!! warning "Names to avoid"
    Methods and variables share a namespace with the words asgard and Thor use internally. Do not name a method `shell`, `options`, `invoke`, `run`, `args` or any other name on that list; a `.loki` that does is refused at load time with the file and line. The list is in [Defining Tasks](tasks.md#reserved-names). `@@options` or `@@shell` as variables are legal but confusing next to the `options` and `shell` methods, so pick something more specific.
