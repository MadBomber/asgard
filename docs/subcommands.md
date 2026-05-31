# Subcommands

Subcommands group related tasks under a common namespace, giving you commands like `asgard server start` or `asgard db migrate`. Asgard uses Thor's `subcommand` method for this, with one important convention: subcommand classes inherit from `Tasks` rather than from `Asgard::Base` or `Thor` directly.

---

## Basic Pattern

Define a subcommand class that inherits from `Tasks`, then register it on the top-level `Tasks` class with `subcommand`:

```ruby
class DeployCommands < Tasks
  desc "Deploy to staging"
  def staging = sh "cap staging deploy"

  desc "Deploy to production"
  def production = sh "cap production deploy"
end

class Tasks
  desc "deploy SUBCOMMAND", "Deploy the application"
  subcommand "deploy", DeployCommands
end
```

```bash
asgard deploy              # shows deploy subcommand help
asgard deploy staging
asgard deploy production
```

---

## Why Inherit from `Tasks`?

Inheriting from `Tasks` (rather than `Asgard::Base` or `Thor`) gives the subcommand class access to:

- `sh` and `shebang` shell helpers (from `Asgard::Shell`)
- `depends_on` for dependency declarations
- `dotenv` for environment loading
- `@@` class variables declared on `Tasks` (visible in all subclasses)
- The built-in `--debug` and `--verbose` class options
- The `debug?` and `verbose?` private predicates
- Any private helpers or `no_commands` methods defined on `Tasks`

!!! warning
    Do **not** redeclare `class_option :debug` or `class_option :verbose` in your subcommand class — they are already inherited from `Tasks`. Redeclaring them causes duplicate option errors.

---

## depends_on Within a Subcommand

`depends_on` works exactly as at the top level, scoped to the subcommand's own dependency graph:

```ruby
class DBCommands < Tasks
  desc "Run pending migrations"
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

---

## Server Subcommand Example

```ruby
class ServerCommands < Tasks
  desc "start [PORT]", "Start the server on PORT (default: 3000)"
  option :daemon,  aliases: "-d", type: :boolean, default: false, desc: "Run as a background daemon"
  option :workers, aliases: "-w", type: :numeric, default: 2,     desc: "Number of worker processes"
  option :log,                    type: :string,  default: "log/server.log",
                                  banner: "FILE", desc: "Write logs to FILE"
  def start(port = "3000")
    flags = []
    flags << "--daemon"              if options[:daemon]
    flags << "--workers #{options[:workers]}"
    flags << "--log #{options[:log]}"
    sh "puma -p #{port} #{flags.join(' ')}"
  end

  desc "Stop the running server"
  option :force, aliases: "-f", type: :boolean, default: false, desc: "Force-kill without draining"
  def stop
    options[:force] ? sh "pkill -9 puma" : sh "pumactl stop"
  end

  desc "Show server status"
  def status = sh "pumactl stats"

  depends_on :stop, :start
  desc "restart [PORT]", "Stop then start"
  def restart(port = "3000") = puts "Server restarted on :#{port}."
end

class Tasks
  desc "server SUBCOMMAND", "Manage the application server"
  subcommand "server", ServerCommands
end
```

```bash
asgard server start
asgard server start 4000 --workers 4 --daemon
asgard server stop --force
asgard server restart
asgard server status
```

---

## Scoped DSL

Each subcommand class has its own independent scope for:

- `desc` / `long_desc` — documentation strings
- `method_option` / `option` — per-command options
- `class_option` — options shared across the subcommand's tasks (in addition to inherited ones)
- `map` — aliases within the subcommand group
- `default_task` — which command runs when the subcommand is invoked with no further arguments
- `depends_on` — dependency declarations scoped to this class

These do not bleed into the parent `Tasks` class or other subcommand classes.

---

## Multiple Subcommands

You can register as many subcommand groups as needed:

```ruby
class ServerCommands < Tasks
  # ... server tasks ...
end

class DBCommands < Tasks
  # ... database tasks ...
end

class DeployCommands < Tasks
  # ... deploy tasks ...
end

class Tasks
  desc "server SUBCOMMAND", "Manage the server";    subcommand "server", ServerCommands
  desc "db SUBCOMMAND",     "Manage the database";  subcommand "db",     DBCommands
  desc "deploy SUBCOMMAND", "Deploy";               subcommand "deploy", DeployCommands
end
```

---

## Subcommands Across Files

Define each subcommand class in its own `.loki` file. Because all files reopen the same Ruby classes, the classes are available when `.loki` registers them:

```
myproject/
  .loki                    ← registers all subcommands
  server_subcommands.loki  ← defines ServerCommands
  db_subcommands.loki      ← defines DBCommands
```

Because siblings loaded via `import "*.loki"` execute before `.loki`'s own class body, both `DBCommands` and `ServerCommands` are defined by the time `.loki` runs its `subcommand` calls.

See [`examples/server_subcommands.loki`](examples.md#server-subcommands) and [`examples/db_subcommands.loki`](examples.md#db-subcommands) for complete working examples.
