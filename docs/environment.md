# Environment Variables

Asgard provides the `dotenv` class method to load `.env` files into the process environment before tasks run. It is a thin wrapper around the [dotenv gem](https://github.com/bkeepers/dotenv).

---

## Basic Usage

Call `dotenv` inside the class body (not inside a task method) to load the default `.env` file:

```ruby
class Tasks
  dotenv   # loads .env from the current working directory

  desc "Print the app name from .env"
  def check = puts env(:app_name)
end
```

### Load a Named File

Pass a file path string to load a specific file:

```ruby
class Tasks
  dotenv ".env.local"     # load a local override
  dotenv ".env.staging"   # load staging-specific vars
end
```

### Multiple Calls

Call `dotenv` multiple times to load several files. Each call merges the loaded variables into `ENV`. Later calls do not overwrite variables already set by earlier calls (standard dotenv behavior):

```ruby
class Tasks
  dotenv              # loads .env (base config)
  dotenv ".env.local" # loads .env.local (local overrides)
end
```

---

## When `dotenv` Runs

`dotenv` is a **class-level** call — it executes at Ruby class-load time, not when a task is invoked. This means:

1. Variables are available in `ENV` before any task method runs.
2. They are available during `depends_on` dependency resolution.

```ruby
class Tasks
  dotenv

  var :database_url, -> { ENV.fetch("DATABASE_URL") }

  desc "Run migrations"
  def migrate = sh "DATABASE_URL=#{database_url} rails db:migrate"
end
```

!!! warning
    If `.env` does not exist, `dotenv` silently does nothing — it checks `File.exist?` before loading. There is no error for a missing file.

---

## File Not Found

Asgard calls `Dotenv.load(path)` only when `File.exist?(path)` is true. If the file is absent, the call is a no-op:

```ruby
class Tasks
  dotenv ".env.local"   # silently skipped if .env.local does not exist
end
```

This makes it safe to commit a `.env.local` line to your `.loki` without requiring every developer to create the file.

---

## Environment Variables vs. Class Variables

Use `dotenv` to bring external configuration into `ENV`. Use `@@` class variables for fixed values declared in the task file, and read from `ENV` directly in task bodies or helper methods when the value comes from the environment:

```ruby
class Tasks
  dotenv

  @@app_name ||= "myapp".freeze

  desc "Start the server"
  def start
    port = ENV.fetch("PORT", "3000").to_i
    sh "puma -b tcp://0.0.0.0:#{port} -w #{ENV.fetch('WORKERS', '2')}"
  end
end
```

For `ENV` values used in multiple tasks, define a private helper method:

```ruby
class Tasks
  dotenv

  desc "Start the server"
  def start = sh "puma -p #{port}"

  desc "Show config"
  def config = puts "#{@@app_name} on port #{port}"

  private

  def port = ENV.fetch("PORT", "3000").to_i
end
```

---

## Dotenv File Format

Standard dotenv file syntax applies:

```bash
# .env
APP_NAME=myapp
DATABASE_URL=postgres://localhost/myapp_development
REDIS_URL=redis://localhost:6379/0
PORT=3000
```

Multi-line values and quotes are supported per the dotenv gem's own documentation.
