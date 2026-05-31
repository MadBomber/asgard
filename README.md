# Asgard

> [!INFO]
> See the [CHANGELOG](CHANGELOG.md) for the latest changes. The [examples directory](examples/) contains working `.loki` files demonstrating the full feature set.

<br>
<table>
<tr>
<td width="40%" align="center" valign="top">
<img src="docs/assets/images/asgard.jpg" alt="Asgard"><br>
<em>"Loki writes the tricks. Asgard runs them."</em>
</td>
<td width="60%" valign="top">
<strong>Key Features</strong><br>

- <strong>Thor-Powered CLI</strong> — every Thor DSL feature available inside <code>.loki</code> task files<br>
- <strong>Task Dependencies</strong> — sequential, parallel, and mixed dependency graphs via <code>depends_on</code><br>
- <strong>Concurrent Execution</strong> — parallel task groups run in native Ruby threads<br>
- <strong>Subcommands</strong> — group related tasks under a named namespace<br>
- <strong>Variables</strong> — shared configuration via Ruby class variables (<code>@@name</code>), visible across all tasks and subcommands<br>
- <strong>Shell Helpers</strong> — <code>sh</code> for any shell command or heredoc; <code>shebang</code> for polyglot scripts<br>
- <strong>Dotenv Support</strong> — load <code>.env</code> files into the environment with <code>dotenv</code><br>
- <strong>Auto-Discovery</strong> — <code>.loki</code> root marker searched from CWD upward through parent directories<br>
- <strong>Multi-File Tasks</strong> — split tasks across <code>*.loki</code> files, loaded via <code>import</code> from your <code>.loki</code><br>
- <strong>Built-in Flags</strong> — <code>--debug</code>, <code>--verbose</code>, and <code>--version</code> built-in class options; header/footer DSL for static help text<br>
</td>
</tr>
</table>

<p>Asgard is a <a href="https://github.com/rails/thor">Thor</a>-based task runner for Ruby projects. Define tasks in <code>.loki</code> files, declare dependencies between them, and let Asgard handle ordering and concurrent execution. Anything Thor can do — subcommands, typed options, argument validation — is available inside a <code>.loki</code> file.</p>

## Installation

```bash
gem install asgard
```

Or add to your Gemfile:

```bash
bundle add asgard
```

---

## Tasks

Every `.loki` file defines tasks as methods inside `class Tasks`. The `Tasks` class is pre-defined by the gem — just reopen it and add methods.

### A task with no parameters

```ruby
class Tasks
  desc "Say hello"
  def hello = puts "Hello, World!"
end
```

```bash
asgard hello
```

### A task with a positional parameter

Declare positional parameters directly in the method signature. Document them in the `desc` usage string:

```ruby
class Tasks
  desc "hello NAME", "Say hello to NAME"
  def hello(name = "World") = puts "Hello, #{name}!"
end
```

```bash
asgard hello
asgard hello Alice
```

### A task with a formal argument declaration

Use `argument` for richer metadata — type checking, enums, and help text. **Warning: `argument` is a class-level declaration that applies to every task in the class**, not just the one below it. It is best suited for single-command CLIs or when every task genuinely shares the same positional input. In multi-task files, prefer method signature parameters instead.

```ruby
class Tasks
  argument :name,
           type:    :string,
           default: "World",
           desc:    "Name to greet"

  desc "hello NAME", "Say hello to NAME"
  def hello = puts "Hello, #{name}!"
end
```

### A task with named options

Use `method_option` (alias: `option`) for named flags. Access them inside the method via `options[:name]`:

```ruby
class Tasks
  desc "hello NAME", "Say hello to NAME"
  method_option :shout,  aliases: "-s", type: :boolean, desc: "Uppercase the output"
  method_option :count,  aliases: "-n", type: :numeric, default: 1, desc: "Repeat N times"
  def hello(name = "World")
    message = options[:shout] ? "HELLO, #{name.upcase}!" : "Hello, #{name}!"
    options[:count].times { puts message }
  end
end
```

```bash
asgard hello Alice --shout --count 3
```

### A task with an extended description

`long_desc` provides detailed help shown by `asgard help <task>`:

```ruby
class Tasks
  long_desc <<~DESC
    Says hello to NAME.
    Repeats the greeting COUNT times.
    Use --shout to uppercase the output.
  DESC
  desc "hello NAME", "Say hello to NAME"
  method_option :shout, aliases: "-s", type: :boolean, desc: "Uppercase the output"
  method_option :count, aliases: "-n", type: :numeric, default: 1, desc: "Repeat N times"
  def hello(name = "World")
    message = options[:shout] ? "HELLO, #{name.upcase}!" : "Hello, #{name}!"
    options[:count].times { puts message }
  end
end
```

---

## Dependencies

`depends_on` declares what must run before a task. Each dependency runs at most once per `asgard` invocation regardless of how many tasks declare it. Circular dependencies are caught at startup.

`desc` and `depends_on` are independent — either can come first, both must appear before `def`.

### Sequential dependencies

Bare symbols run one after another in the order declared:

```ruby
class Tasks
  desc "Compile the project"
  def build = sh "rake build"

  depends_on :build
  desc "Run the test suite"
  def test = sh "rake test"

  depends_on :test
  desc "Publish the gem"
  def release = sh "bundle exec rake release"
end
```

```bash
asgard release   # build → test → release
```

### Parallel dependencies

Wrap symbols in an array to declare they can run concurrently. Asgard waits for all tasks in a parallel group to finish before moving to the next stage:

```ruby
class Tasks
  desc "Check code style"
  def lint = sh "bundle exec rubocop"

  desc "Run type checks"
  def typecheck = sh "bundle exec srb tc"

  # lint and typecheck run in parallel, test waits for both
  depends_on [:lint, :typecheck]
  desc "Run the test suite"
  def test = sh "bundle exec rake test"
end
```

```bash
asgard test   # lint ∥ typecheck → test
```

### Mixed sequential and parallel

Mix bare symbols (sequential) and arrays (parallel) in a single `depends_on` call. Execution proceeds stage by stage — each stage must complete before the next begins:

```ruby
class Tasks
  desc "Install dependencies"; def setup  = sh "bundle install"
  desc "Check code style";     def lint   = sh "bundle exec rubocop"
  desc "Compile assets";       def build  = sh "rake assets:precompile"
  desc "Run tests";            def test   = sh "bundle exec rake test"
  desc "Post to Slack";        def notify = sh "curl $SLACK_WEBHOOK -d '{\"text\":\"done\"}'"

  # setup first, then lint+build in parallel, then test, then notify
  depends_on :setup, [:lint, :build], :test, :notify
  desc "Full CI pipeline"
  def ci = puts "CI complete"
end
```

```
asgard ci executes:

  setup
    ↓
  lint ∥ build    (concurrent)
    ↓
  test
    ↓
  notify
    ↓
  ci
```

---

## Variables

Shared configuration values are declared as Ruby class variables (`@@name`) at the top of the class body. Use `||=` so the first declaration wins when multiple `.loki` files reopen `Tasks`, and `.freeze` to prevent mutation:

```ruby
class Tasks
  @@app     ||= "myapp".freeze
  @@max_jobs ||= 4

  desc "Create a release tag"
  def tag = sh "git tag #{@@app}-#{version}"

  private

  def version = `git describe --tags`.strip
end
```

Class variables are visible in all task instance methods and in subcommand subclasses — unlike class instance variables (`@name`), which are not accessible inside instance methods.

---

## Helper methods

Private methods are callable from any task in the same class but are never registered as commands — they won't appear in `--help` output and can't be invoked from the CLI.

```ruby
class Tasks
  desc "Compile and package"
  def build
    compile("src")
    package(version)
  end

  desc "Build and publish"
  def release
    build
    sh "gem push pkg/myapp-#{version}.gem"
  end

  private

  def compile(dir)
    sh "gcc -O2 -o bin/myapp #{dir}/*.c"
  end

  def package(ver)
    sh "tar czf pkg/myapp-#{ver}.tar.gz bin/"
  end
end
```

Helpers can also be shared across multiple `.loki` files by extracting them into a plain Ruby file and loading it explicitly:

```ruby
# shared/helpers.rb
module BuildHelpers
  private

  def compile(dir)
    sh "gcc -O2 -o bin/myapp #{dir}/*.c"
  end
end

# .loki
require_relative "shared/helpers"

class Tasks
  include BuildHelpers

  desc "Compile the project"
  def build = compile("src")
end
```

---

## Help header and footer

Add static text above and below the command list in `asgard help` output:

```ruby
class Tasks
  header "my-project — build & release tasks"
  footer "See https://example.com/docs for details"
end
```

Multiple calls accumulate. `header` appends each line (top to bottom); `footer` prepends each line (bottom to top), so content from a later-loaded `.loki` file sits closer to the commands:

```ruby
# .loki
class Tasks
  header "my-project"
  footer "Maintainer: you@example.com"
end

import "*.loki"

# deploy.loki
class Tasks
  header "  deploy targets: staging, production"
  footer "See runbook at wiki/deploy"
end
```

```
my-project
  deploy targets: staging, production

Commands:
  ...

Options:
  ...

See runbook at wiki/deploy
Maintainer: you@example.com
```

Header and footer text is only shown for the general `asgard help` page, not for `asgard help <command>`.

---

## Options shared across all tasks

`class_option` defines an option available to every task in the class:

```ruby
class Tasks
  class_option :dry_run, aliases: "-n", type: :boolean, desc: "Print commands without running"

  desc "deploy ENV", "Deploy to the given environment"
  def deploy(env = "staging")
    if options[:dry_run]
      puts "Would deploy to #{env}"
    else
      sh "cap #{env} deploy"
    end
  end
end
```

---

## Shell helpers

`sh` runs any shell command or multiline heredoc. `shebang` writes a script body to a tempfile and executes it with the given interpreter. Both exit with the command's status code on failure.

```ruby
class Tasks
  desc "Bootstrap the development environment"
  def setup
    sh <<~SHELL
      brew install redis postgresql
      brew services start redis
      bundle install
      rails db:setup
    SHELL
  end

  desc "Run Python data analysis"
  def analyze
    shebang :python3, <<~PYTHON
      import json
      data = json.load(open("results.json"))
      print(f"Total: {sum(data.values())}")
    PYTHON
  end

  desc "Build frontend assets with esbuild"
  def bundle_assets
    shebang :node, <<~JS
      const esbuild = require("esbuild")
      esbuild.buildSync({ entryPoints: ["src/app.js"], bundle: true, outfile: "dist/app.js" })
    JS
  end
end
```

Supported interpreters: `:python3`, `:python`, `:node`, `:ruby`, `:perl`, `:bash`, `:sh`. Any other symbol is passed directly to `system` with a `.tmp` extension.

Pass `silent: true` to both `sh` and `shebang` to suppress the script echo:

```ruby
def build   = sh "rake build", silent: true
def analyze = shebang :python3, <<~PY, silent: true
  import json
  print(json.load(open("data.json")))
PY
```

---

## Environment variables

`dotenv` loads a `.env` file into the environment before tasks run. Use the `env` Kernel method to read environment variables inside task bodies — it accepts a symbol or string and upcases the key automatically:

```ruby
class Tasks
  dotenv              # loads .env
  dotenv ".env.local" # or a specific file

  desc "Start the server"
  def start
    sh "puma -p #{env(:port, '3000')} -e #{env(:rack_env, 'development')}"
  end

  desc "Deploy the app"
  def deploy
    sh "cap #{env(:deploy_target)} deploy"  # raises KeyError if DEPLOY_TARGET is unset
  end
end
```

| Call | Behaviour |
|------|-----------|
| `env(:port, "3000")` | Returns `"3000"` when `PORT` is unset |
| `env(:api_key)` | Raises `KeyError` when `API_KEY` is missing |
| `env("DATABASE_URL")` | String name works too — always upcased |

---

## Command aliases

`map` creates alternative names for a task:

```ruby
class Tasks
  map "-v"  => "version"
  map "--v" => "version"
  map "t"   => "test"

  desc "Print the version"
  def version = puts Asgard::VERSION
end
```

---

## Subcommands

Group related tasks under a common name using Thor's `subcommand` method. Define a subcommand class that inherits from `Tasks`, then register it with a name and description.

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
asgard deploy           # shows deploy subcommand help
asgard deploy staging
asgard deploy production
```

Subcommand tasks have all the same access to `sh`, `shebang`, `depends_on`, and the built-in `--debug`/`--verbose` class options as normal tasks. `@@` class variables declared on `Tasks` are also visible in subcommand subclasses.

`depends_on` only works within a subcommand group exactly as it does at the top level:

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

Each subcommand group can have its own `desc`, `long_desc`, `option`, `class_option`, and `map` declarations, all scoped to that group.

See [`examples/server_subcommands.loki`](examples/server_subcommands.loki) and [`examples/db_subcommands.loki`](examples/db_subcommands.loki) for full working examples.

---

## `method_option` types reference

| Type | CLI example | Ruby value |
|---|---|---|
| `:string` | `--branch main` | `"main"` |
| `:boolean` | `--force` / `--no-force` | `true` / `false` |
| `:numeric` | `--count 3` | `3` |
| `:array` | `--tags foo bar baz` | `["foo", "bar", "baz"]` |
| `:hash` | `--vars KEY:val FOO:bar` | `{"KEY"=>"val", "FOO"=>"bar"}` |

Common `method_option` keys: `aliases`, `type`, `default`, `required`, `desc`, `enum`, `banner`.

---

## Task files

Asgard searches the current directory and its ancestors for a `.loki` file. That file marks the project root. Additional `*.loki` files are loaded only when your `.loki` file explicitly calls `import`.

### Single file

```
myproject/
  .loki
```

### Multiple files

Split tasks across files — each reopens `class Tasks`:

```
myproject/
  .loki          ← entry point; calls import to load task files
  build.loki
  deploy.loki
  test.loki
```

The `.loki` entry file must call `import` to load the other task files. It also marks the project root for auto-discovery:

```ruby
# .loki
import "*.loki"
```

```ruby
# build.loki
class Tasks
  desc "Compile the project"
  def build = sh "rake build"
end
```

```ruby
# test.loki
class Tasks
  depends_on :build
  desc "Run the test suite"
  def test = sh "bundle exec rake test"
end
```

```ruby
# deploy.loki
class Tasks
  depends_on :test
  desc "Deploy to production"
  def deploy = sh "cap production deploy"
end
```

In a single-file project, `.loki` can be completely empty — its presence alone marks the project root. In a multi-file project, add at least an `import` call.

### Explicit loading

Load any Ruby or `.loki` file manually from `.loki`. Use `require_relative` for plain Ruby; use `import` for `.loki` files (it enforces the extension and is idempotent):

```ruby
# .loki
require_relative "shared/helpers"
import "ci.loki"

class Tasks
  # additional tasks
end
```

---

## `Asgard` module API

| Method | Description |
|---|---|
| `Asgard.run!(argv)` | Entry point — finds `.loki`, loads task files, starts CLI |
| `Asgard.find_task_file` | Returns a `Pathname` to `.loki` searching from CWD upward, or `nil` |

`run!` handles its own errors — a missing `.loki`, a circular dependency, or a `depends_on` that names a task that doesn't exist all produce a clean one-line message and exit 1.

---

## Development

```bash
git clone git@github.com:MadBomber/asgard.git
cd asgard
bundle install
bundle exec rake test       # run tests (95% coverage minimum enforced)
bundle exec bin/asgard help # exercise the CLI against this gem's own .loki
```

## Contributing

Bug reports and pull requests are welcome at https://github.com/MadBomber/asgard.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
