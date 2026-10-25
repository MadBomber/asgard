# Subcommands

A subcommand groups related tasks under one name, so you type `asgard db migrate` and `asgard server start` instead of `migrate_db` and `start_server`. Each group is its own class with its own tasks, options and help page.

The whole pattern in one file:

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
asgard deploy staging
asgard deploy production
asgard deploy              # the group's help
```

The rest of this page explains what the subcommand class gets from `Tasks`, how dependencies and options work inside it, and how to lay out several groups across files.

---

## The Pattern

A subcommand needs two things:

1. **A class that inherits from `Tasks`.** Its public methods with a `desc` are the group's tasks, exactly as in `Tasks` itself. The class name is yours to choose; `DeployCommands`, `Deploy` and `DeployTasks` all work.
2. **A registration on `Tasks`** with `subcommand "name", TheClass`, preceded by a `desc` whose usage string is conventionally `name SUBCOMMAND`. The description is what `asgard help` shows next to the group.

The class must exist before the `subcommand` line runs. In a single file, write the class first. Across files, import the file that defines the class before the `class Tasks` body that registers it (see [Across Files](#subcommands-across-files)).

---

## Why Inherit from `Tasks`

Inheriting from `Tasks` gives the group everything a top-level task has:

- `sh` and `shebang`, and the same `shells` registry and `default_shell` (one registry for the whole project, so a `shell :bash, "/opt/homebrew/bin/bash"` in `.loki` applies here too)
- `depends_on`, scoped to the group's own tasks
- `dotenv` and `env`
- `@@` class variables declared on `Tasks`, visible in every task of the group
- The built-in `--debug` and `--verbose` options, and `debug?` / `verbose?`
- Any `class_option` you added to `Tasks`
- Every private helper, `no_commands` method and `helper` defined on `Tasks`

Two consequences of inheritance to know about:

- **The group inherits the top-level tasks as well.** `asgard db deploy` runs the top-level `deploy`, and `asgard db help` lists the inherited tasks above the group's own, under a namespace made from the class name (`asgard d_b_commands deploy`). Harmless, but it is why the group's help is longer than you might expect.
- **A `default_task` on `Tasks` is inherited too.** If `.loki` says `default_task :greet`, then `asgard db` with no further word runs `greet`, not the group's help. Set the group's own default:

    ```ruby
    class DBCommands < Tasks
      default_task :help
      # ...
    end
    ```

!!! warning
    Do not redeclare `class_option :debug` or `class_option :verbose` in a subcommand class. They are inherited; declaring them again is an error.

---

## `depends_on` Within a Subcommand

`depends_on` works inside the group exactly as at the top level, and names the group's own tasks:

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

Each task still runs at most once per invocation, parallel groups still run in threads, and cycles and undefined names are still caught before anything runs. See [Dependencies](dependencies.md).

---

## A Complete Example: Server Commands

This group starts, stops and restarts a server, and remembers the port it was started on so `stop` and `restart` use the same one. It is the `examples/server_subcommands.loki` file from the repository:

```ruby
SERVER_PORT_FILE = "tmp/.server.port".freeze

class ServerCommands < Tasks
  default_task :help     # `asgard server` shows this group's help

  # Available both in the class body and inside the tasks below
  helper(:server_port) {
    File.exist?(SERVER_PORT_FILE) ? File.read(SERVER_PORT_FILE).strip.to_i : 3000
  }

  desc "Start the server"
  option :port,    aliases: "-p", type: :numeric, default: 3000,  desc: "Port to listen on"
  option :daemon,  aliases: "-d", type: :boolean, default: false, desc: "Run as a background daemon"
  option :workers, aliases: "-w", type: :numeric, default: 2,     desc: "Number of worker processes"
  option :log,                    type: :string,  default: "log/server.log",
                                  banner: "FILE", desc: "Write logs to FILE"
  def start
    FileUtils.mkdir_p("tmp")
    File.write(SERVER_PORT_FILE, options[:port].to_s)
    puts "Starting server on :#{options[:port]} with #{options[:workers]} workers#{options[:daemon] ? ' (daemon)' : ''}..."
  end

  desc "Stop the running server"
  option :force, aliases: "-f", type: :boolean, default: false, desc: "Force-kill without draining"
  option :wait,                  type: :numeric, default: 30,   desc: "Seconds to wait for shutdown"
  def stop
    if options[:force]
      puts "Force-stopping server on :#{server_port}..."
    else
      puts "Gracefully stopping server on :#{server_port} (timeout: #{options[:wait]}s)..."
    end
  end

  desc "Show server status and process info"
  def status = puts "Server is listening on :#{server_port}"

  depends_on :stop
  desc "Restart the server on the same port it was started on"
  def restart
    puts "Starting server on :#{server_port}..."
    puts "Server restarted."
  end
end

class Tasks
  desc "server SUBCOMMAND", "Manage the application server"
  subcommand "server", ServerCommands
end
```

```bash
asgard server start -p 4000 --workers 4 --daemon
# Starting server on :4000 with 4 workers (daemon)...
asgard server status
# Server is listening on :4000
asgard server restart
# Gracefully stopping server on :4000 (timeout: 30s)...
# Starting server on :4000...
# Server restarted.
asgard server stop --force
```

Everything from [Defining Tasks](tasks.md) applies inside the group: per-task options, `long_desc`, `map` for short names, positional parameters.

---

## Scoped Declarations

Each subcommand class has its own:

| Declaration | Scope |
|---|---|
| `desc`, `long_desc` | The group's tasks |
| `method_option` / `option` | The task that follows |
| `class_option` | Every task in the group, in addition to the ones inherited from `Tasks` |
| `map` | Short names within the group: `map "m" => "migrate"` makes `asgard db m` work |
| `default_task` | What `asgard db` alone runs |
| `depends_on` | The group's own tasks |

None of these leak back into `Tasks` or into another group.

---

## Several Groups

Register as many as you need:

```ruby
class ServerCommands < Tasks
  # ...
end

class DBCommands < Tasks
  # ...
end

class DeployCommands < Tasks
  # ...
end

class Tasks
  desc "server SUBCOMMAND", "Manage the server";   subcommand "server", ServerCommands
  desc "db SUBCOMMAND",     "Manage the database"; subcommand "db",     DBCommands
  desc "deploy SUBCOMMAND", "Deploy";              subcommand "deploy", DeployCommands
end
```

`asgard help` lists each group on one line (`asgard db SUBCOMMAND  # Manage the database`); `asgard tree` adds a section per group, named after its class (`d_b_commands`), listing the group's own tasks.

---

## Subcommands Across Files

Give each group its own file and register them all in `.loki`:

```
myproject/
  .loki                    imports the siblings, then registers the groups
  server_subcommands.loki  defines ServerCommands
  db_subcommands.loki      defines DBCommands
```

```ruby
# .loki
import "*.loki"

class Tasks
  desc "server SUBCOMMAND", "Manage the server";   subcommand "server", ServerCommands
  desc "db SUBCOMMAND",     "Manage the database"; subcommand "db",     DBCommands
end
```

The `import` at the top of `.loki` loads the siblings before `.loki`'s own `class Tasks` body runs, so both classes are defined by the time the `subcommand` lines need them. See [Task Files](task-files.md#subcommand-classes-in-their-own-files).

---

## Help for a Group

Three spellings reach the group's help:

```bash
asgard db            # the group's help (when the group has no default task of its own)
asgard db help       # the same
asgard help db       # the same
asgard db help migrate   # one task of the group
```

```
Commands:
  asgard db console             # Open an interactive database console
  asgard db help [COMMAND]      # Describe subcommands or one specific subcommand
  asgard db migrate [VERSION]   # Run pending migrations up to VERSION
  asgard db reset               # Rollback all migrations, re-migrate, and reseed
  ...
```

The inherited top-level tasks appear in the same listing under the class's namespace, as noted above.

---

## The Built-in Groups

`asgard schedule`, `asgard watcher` and `asgard jobs` are subcommand groups too, built into asgard. They are registered under reserved names, so a task of your own called `schedule`, `watcher` or `jobs` does not shadow them: `asgard schedule install` always reaches the built-in. See [Scheduled Tasks](schedule.md), [Watched Files](watch.md) and [Background Jobs](jobs.md).
