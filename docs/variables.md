# Variables

Asgard task files are plain Ruby. Shared configuration values are declared using Ruby class variables (`@@name`) at the top of the `Tasks` class body.

---

## Ruby Variable Types

Ruby has four kinds of variables plus constants, each with a distinct prefix and scope. Understanding the differences matters because tasks are instance methods — the wrong variable type will simply not be visible where you expect it.

| Kind | Prefix | Example | Scope |
|------|--------|---------|-------|
| Local | none | `count = 0` | The method or block it is defined in only |
| Instance | `@` | `@name = "myapp"` | One specific object instance |
| Class | `@@` | `@@name = "myapp"` | The class and all its subclasses |
| Global | `$` | `$DEBUG = true` | Everywhere in the process |
| Constant | uppercase first letter | `APP = "myapp"` | Everywhere (namespaced to where defined) |

### Local variables

```ruby
def build
  output_dir = "dist"   # only visible inside this method
  sh "rake build OUTDIR=#{output_dir}"
end
```

`output_dir` disappears when the method returns. It cannot be seen by any other task.

### Instance variables (`@`)

```ruby
class Tasks
  @app = "myapp"   # class instance variable — lives on the Tasks class object

  def build
    puts @app      # nil — this @app is on the instance, not the class
  end
end
```

`@` in the class body sets a variable on the class object itself, not on the instances that run tasks. Inside a task method body, `@name` refers to the instance, which is a different object. They do not share state.

`@` inside a method is useful for memoization within a single task invocation:

```ruby
def version
  @version ||= `git describe --tags`.strip   # computed once, cached for this run
end
```

### Class variables (`@@`)

```ruby
class Tasks
  @@app = "myapp"   # visible in every task method and every subclass

  def build
    puts @@app      # "myapp"
  end
end
```

`@@` is shared across the class body, all instance methods, and all subclasses (including Thor subcommand classes). This makes it the right choice for configuration values in Asgard task files.

### Global variables (`$`)

```ruby
$DEBUG   = true   # visible everywhere in the Ruby process
$VERBOSE = true
```

Asgard uses `$DEBUG` and `$VERBOSE` internally — they are set by the `--debug` and `--verbose` CLI flags. Avoid declaring your own `$` variables in `.loki` files; they affect the entire Ruby process including all loaded gems.

Several important Ruby globals you may encounter in task files:

| Variable | Purpose |
|----------|---------|
| `$stdout` / `$STDOUT` | Standard output stream — `puts` writes here |
| `$stderr` / `$STDERR` | Standard error stream — `warn` writes here |
| `$DEBUG` | Enables debug mode when `true` |
| `$VERBOSE` | Enables verbose warnings when `true` |
| `$PROGRAM_NAME` / `$0` | The name of the running script |

The uppercase versions (`$STDOUT`, `$STDERR`) are the original stream objects. The lowercase versions (`$stdout`, `$stderr`) are reassignable aliases — libraries sometimes redirect them temporarily to capture output. In task files, use `$stdout.puts` or `$stderr.puts` when you need explicit stream control; use plain `puts` and `warn` for normal output.

### Constants

Any name that begins with an uppercase letter is a constant in Ruby. Constants are available everywhere — inside methods, across files, and across classes — without any prefix:

```ruby
APP_NAME    = "myapp".freeze
MAX_RETRIES = 3
BASE_URL    = "https://example.com".freeze

class Tasks
  desc "Deploy the app"
  def deploy
    puts "Deploying #{APP_NAME} to #{BASE_URL}"
    sh "cap deploy"
  end
end
```

The convention is `ALL_CAPS_WITH_UNDERSCORES` for values that are truly fixed. Class and module names are also constants — `Tasks`, `Asgard`, `String`, `Integer` all start with an uppercase letter.

Ruby will issue a warning if you reassign a constant but will not prevent it. Use `.freeze` to make the value itself immutable:

```ruby
APP_NAME = "myapp".freeze   # value cannot be mutated; reassignment still warns
```

**Constants vs `@@` class variables in task files:**

| | Constant | `@@` class variable |
|---|---|---|
| Accessible in task methods | Yes | Yes |
| Accessible in subcommand subclasses | Yes | Yes |
| Visible outside the class | Yes — anywhere | Only within the class hierarchy |
| Reassignment warning | Yes | No |
| Convention | `ALL_CAPS` | `snake_case` |

For fixed values that will never change — app names, version strings, URLs, port numbers — constants are often the clearest choice. For values that might reasonably vary across environments or be overridden in a different `.loki` file, `@@` with `||=` is more flexible.

---

## Strings and Interpolation

### Always use double quotes

Ruby supports both single and double quoted strings. In Asgard task files, always use double quotes:

```ruby
@@app ||= "myapp".freeze     # correct
sh "bundle exec rake test"   # correct
```

Single-quoted strings look similar but behave differently — they do not support interpolation or escape sequences. Mixing the two styles adds confusion for no benefit. Double quotes work everywhere single quotes do, and more.

### String interpolation

Embedding a variable's value inside a string uses the `#{}` syntax. Everything inside the braces is Ruby code — the result is converted to a string and inserted in place:

```ruby
class Tasks
  @@app  ||= "myapp".freeze
  @@env  ||= "production".freeze

  desc "Deploy the app"
  def deploy
    sh "cap #{@@env} deploy APP=#{@@app}"
  end
end
```

Any Ruby expression works inside `#{}`:

```ruby
puts "build started at #{Time.now}"
sh "puma -p #{env(:port, '3000').to_i + 1}"
sh "git tag #{@@app}-#{`git describe --tags`.strip}"
```

Interpolation only works inside double-quoted strings. This is the primary reason Asgard tasks use double quotes exclusively — shell commands almost always need to embed variable values.

### Multi-line strings

For shell scripts with multiple lines, use a heredoc. The `~` modifier strips leading indentation so the script aligns with your code:

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

Interpolation works inside heredocs the same as in double-quoted strings.

---

## System Environment Variables

System environment variables are set outside Ruby — in the shell, a CI environment, or a `.env` file — and are accessed inside tasks via the `env` Kernel method:

```ruby
class Tasks
  desc "Start the server"
  def start
    sh "puma -p #{env(:port, '3000')} -e #{env(:rack_env, 'development')}"
  end

  desc "Deploy the app"
  def deploy
    sh "cap #{env(:deploy_target)} deploy"  # raises KeyError if DEPLOY_TARGET is not set
  end
end
```

`env` accepts a symbol or string and converts it to an uppercase `ENV` key automatically:

| Call | Equivalent | Behaviour |
|------|-----------|-----------|
| `env(:port, "3000")` | `ENV.fetch("PORT", "3000")` | Returns `"3000"` if `PORT` is unset |
| `env(:api_key)` | `ENV.fetch("API_KEY")` | Raises `KeyError` if `API_KEY` is unset |
| `env("DATABASE_URL")` | `ENV.fetch("DATABASE_URL")` | Raises `KeyError` if unset |
| `env("database_url")` | `ENV.fetch("DATABASE_URL")` | Same — name is always upcased |

!!! note
    All environment variable values are strings. Convert to other types explicitly: `env(:port, "3000").to_i`, `env(:debug, "false") == "true"`.

Use `dotenv` to load a `.env` file before tasks run — see [Environment](environment.md).

---

## The Pattern

```ruby
class Tasks
  @@app  ||= "myapp".freeze
  @@port ||= 3000
  @@env  ||= "production".freeze

  desc "Print app info"
  def info
    puts "#{@@app} running on port #{@@port} in #{@@env}"
  end
end
```

**Why `||=` instead of `=`?**
Because multiple `.loki` files reopen the same `class Tasks`. Using `||=` means the first file to declare a value wins, and subsequent files that reopen `Tasks` won't accidentally overwrite it.

**Why `.freeze`?**
It prevents mutation of the value (e.g. `@@app << "-extra"` raises a `FrozenError`). Numbers and symbols are already frozen. Use `.freeze` on strings, arrays, and hashes.

**Why `@@` instead of `@`?**
A single `@` in the class body sets a class instance variable — it lives on the `Tasks` class object and is **not** accessible inside task method bodies. `@@` is a class variable and is visible everywhere: in all instance methods, and in any subclass (including Thor subcommand classes).

---

## Sharing Values Across Subcommands

Class variables are visible in subclasses, which makes them the right choice when you have Thor subcommands defined in separate classes:

```ruby
# config.loki
class Tasks
  @@app ||= "myapp".freeze
end

# deploy.loki
class DeployCommands < Tasks
  desc "Deploy to production"
  def production
    sh "cap production deploy APP=#{@@app}"  # @@app is visible here
  end
end

class Tasks
  desc "deploy SUBCOMMAND", "Deployment tasks"
  subcommand "deploy", DeployCommands
end
```

---

## Computed Values

For values that require a shell call, file read, or any runtime computation, define a method instead:

```ruby
class Tasks
  def version = `git describe --tags`.strip
  def sha     = `git rev-parse --short HEAD`.strip

  desc "Show version info"
  def info = puts "#{version} (#{sha})"
end
```

Methods defined without `desc` do not appear in `--help` output or as CLI commands. If you need memoization (the computation is expensive and called multiple times), use `||=` on an instance variable inside the method:

```ruby
class Tasks
  def version
    @version ||= `git describe --tags`.strip
  end
end
```

---

## Sharing Values Across Files

Because all `.loki` files reopen the same `class Tasks`, a `@@` variable declared in one file is available in all other files loaded in the same session:

```ruby
# config.loki
class Tasks
  @@app  ||= "myapp".freeze
  @@port ||= 8080
end

# deploy.loki
class Tasks
  desc "Deploy the app"
  def deploy = sh "cap deploy APP=#{@@app} PORT=#{@@port}"
end
```

---

## Naming Conventions

Class variable names use `snake_case` — the standard Ruby convention for variables and methods:

```ruby
class Tasks
  @@app_name    ||= "myapp".freeze
  @@deploy_host ||= "production.example.com".freeze
  @@max_workers ||= 4
end
```

Multi-word names are separated by underscores, not camelCase or hyphens.

---

## Naming Caution

!!! warning
    Avoid `@@` names that conflict with built-in Ruby or Thor internals. Safe practice: use descriptive names that are unlikely to clash.

Names to avoid: `options`, `shell`, `invoke`, `command`, `args`.
