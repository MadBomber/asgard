# Asgard

A [just](https://just.systems)-like task runner for Ruby. Built on [Thor](https://github.com/rails/thor) for argument handling and [Dagwood](https://github.com/rewindio/dagwood) for dependency ordering.

The name comes from Norse mythology: **Thor** is the CLI framework, **Asgard** is the realm where tasks live, and the task file is named **loki** — because Loki holds all the tricks.

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
  desc "hello", "Say hello"
  def hello = sh 'echo "Hello, World!"'
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
  def hello(name = "World") = sh "echo 'Hello, #{name}!'"
end
```

```bash
asgard hello
asgard hello Alice
```

### A task with a formal argument declaration

Use `argument` for richer metadata — type checking, enums, and help text:

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

### A task with named options

Use `method_option` (alias: `option`) for named flags. Access them inside the method via `options[:name]`:

```ruby
class Tasks
  desc "hello NAME", "Say hello to NAME"
  method_option :shout,  aliases: "-s", type: :boolean, desc: "Uppercase the output"
  method_option :count,  aliases: "-n", type: :numeric, default: 1, desc: "Repeat N times"
  def hello(name = "World")
    message = options[:shout] ? "HELLO, #{name.upcase}!" : "Hello, #{name}!"
    options[:count].times { sh "echo '#{message}'" }
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
    options[:count].times { sh "echo '#{message}'" }
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
  desc "build", "Compile the project"
  def build = sh "rake build"

  depends_on :build
  desc "test", "Run the test suite"
  def test = sh "rake test"

  depends_on :test
  desc "release", "Publish the gem"
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
  desc "lint", "Check code style"
  def lint = sh "bundle exec rubocop"

  desc "typecheck", "Run type checks"
  def typecheck = sh "bundle exec srb tc"

  # lint and typecheck run in parallel, test waits for both
  depends_on [:lint, :typecheck]
  desc "test", "Run the test suite"
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
  desc "setup",  "Install dependencies"; def setup  = sh "bundle install"
  desc "lint",   "Check code style";     def lint   = sh "bundle exec rubocop"
  desc "build",  "Compile assets";       def build  = sh "rake assets:precompile"
  desc "test",   "Run tests";            def test   = sh "bundle exec rake test"
  desc "notify", "Post to Slack";        def notify = sh "curl $SLACK_WEBHOOK -d '{\"text\":\"done\"}'"

  # setup first, then lint+build in parallel, then test, then notify
  depends_on :setup, [:lint, :build], :test, :notify
  desc "ci", "Full CI pipeline"
  def ci = sh "echo 'CI complete'"
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

`var` declares a named value available to all tasks as a method. Pass a lambda for lazy evaluation — it is called once on first use:

```ruby
class Tasks
  var :app,     "myapp"
  var :version, -> { `git describe --tags`.strip }

  desc "tag", "Create a release tag"
  def tag = sh "git tag #{app}-#{version}"
end
```

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
  desc "setup", "Bootstrap the development environment"
  def setup
    sh <<~SHELL
      brew install redis postgresql
      brew services start redis
      bundle install
      rails db:setup
    SHELL
  end

  desc "analyze", "Run Python data analysis"
  def analyze
    shebang :python3, <<~PYTHON
      import json
      data = json.load(open("results.json"))
      print(f"Total: {sum(data.values())}")
    PYTHON
  end

  desc "bundle_assets", "Build frontend assets with esbuild"
  def bundle_assets
    shebang :node, <<~JS
      const esbuild = require("esbuild")
      esbuild.buildSync({ entryPoints: ["src/app.js"], bundle: true, outfile: "dist/app.js" })
    JS
  end
end
```

Supported interpreters: `:python3`, `:python`, `:node`, `:ruby`, `:perl`, `:bash`, `:sh`. Any other symbol is passed directly to `system` with a `.tmp` extension.

Pass `silent: true` to suppress the command echo:

```ruby
def build = sh "rake build", silent: true
```

---

## Environment variables

`dotenv` loads a `.env` file into the environment before tasks run:

```ruby
class Tasks
  dotenv              # loads .env
  dotenv ".env.local" # or a specific file

  desc "check", "Print the app name from .env"
  def check = sh "echo $APP_NAME"
end
```

---

## Command aliases

`map` creates alternative names for a task:

```ruby
class Tasks
  map "-v"  => "version"
  map "--v" => "version"
  map "t"   => "test"

  desc "version", "Print the version"
  def version = puts Asgard::VERSION
end
```

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

Asgard searches the current directory and its ancestors for a `.loki` file. That file marks the project root. All `*.loki` files in the same directory are auto-loaded alphabetically before `.loki` is loaded.

### Single file

```
myproject/
  .loki
```

### Multiple files

Split tasks across files — each reopens `class Tasks`:

```
myproject/
  .loki          ← entry point, can be empty
  build.loki
  deploy.loki
  test.loki
```

```ruby
# build.loki
class Tasks
  desc "build", "Compile the project"
  def build = sh "rake build"
end
```

```ruby
# test.loki
class Tasks
  depends_on :build
  desc "test", "Run the test suite"
  def test = sh "bundle exec rake test"
end
```

```ruby
# deploy.loki
class Tasks
  depends_on :test
  desc "deploy", "Deploy to production"
  def deploy = sh "cap production deploy"
end
```

The `.loki` entry point can be completely empty — it only needs to exist to mark the project root.

### Explicit loading

Load any Ruby or `.loki` file manually from `.loki`:

```ruby
# .loki
require_relative "shared/helpers"
require_relative "ci.loki"

class Tasks
  # additional tasks
end
```

---

## `Asgard` module API

| Method | Description |
|---|---|
| `Asgard.run!(argv)` | Entry point — finds `.loki`, loads task files, starts CLI |
| `Asgard.find_task_file` | Returns path to `.loki` searching from CWD upward, or nil |
| `Asgard.load_loki(dir)` | Loads all `*.loki` files in dir alphabetically |

`run!` handles its own errors — a missing `.loki` or a circular dependency both produce a clean one-line message and exit 1.

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
