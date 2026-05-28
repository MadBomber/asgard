# Asgard

A [just](https://just.systems)-like task runner for Ruby. Define project recipes in a `.loki` file and run them with the `asgard` command. Built on [Thor](https://github.com/rails/thor) for argument handling and [SimpleFlow](https://github.com/madbomber/simple_flow) for dependency ordering.

The name comes from Norse mythology: **Thor** is the CLI framework, **Asgard** is the realm where tasks live, and the task file is named **loki** — because Loki holds all the tricks.

## Installation

```bash
gem install asgard
```

Or add to your Gemfile:

```bash
bundle add asgard
```

## Quick Start

Create a `.loki` file at your project root. `sh` runs any shell command — a single line or a multiline heredoc:

```ruby
# filename: .loki

class Tasks < Asgard::Base
  desc "deps", "Install project dependencies"
  def deps
    sh <<~SHELL
      brew install redis
      npm install
      bundle install
    SHELL
  end

  depends_on :deps
  desc "test", "Run the test suite"
  def test
    sh "bundle exec rake test"
  end

  depends_on :test
  desc "release", "Tag and publish the gem"
  def release
    sh <<~SHELL
      git tag v$(ruby -r./lib/my_gem/version -e 'puts MyGem::VERSION')
      git push --tags
      bundle exec rake release
    SHELL
  end
end
```

Then run tasks from any directory in the project tree:

```bash
asgard test       # runs deps, then test
asgard release    # runs deps, then test, then release
asgard help       # list all available tasks
```

## Task Files

Asgard searches the current directory and its ancestors for task files, in this order:

1. **`.loki`** — the hidden default. Found alone, takes priority over everything.
2. **`*.loki`** — all matching files loaded alphabetically when no `.loki` exists.

This means you can split a large task set across multiple files:

```
deploy.loki
test.loki
build.loki        # loaded as: build.loki, deploy.loki, test.loki
```

Or use a single hidden default:

```
.loki             # takes priority, *.loki files are ignored
```

## Features

### Task dependencies

```ruby
depends_on :build
desc "test", "Run tests"
def test
  sh "bundle exec rake test"
end
```

Dependencies run before the recipe, at most once per invocation regardless of how many recipes declare them. Circular dependencies are caught at startup via `SimpleFlow::DependencyGraph`.

### Variables

```ruby
var :app,     "myapp"
var :version, -> { `git describe --tags`.strip }   # lazy, evaluated on first use

desc "tag", "Create a git tag"
def tag
  sh "git tag #{version}"
end
```

### Multi-line shell scripts

```ruby
desc "setup", "Bootstrap the dev environment"
def setup
  sh <<~SHELL
    brew install redis postgresql
    brew services start redis
    bundle install
    rails db:setup
  SHELL
end
```

### Embedded scripts in other languages

```ruby
desc "analyze", "Run data analysis"
def analyze
  shebang :python3, <<~PYTHON
    import json
    data = json.load(open("results.json"))
    print(f"Total: {sum(data.values())}")
  PYTHON
end

desc "bundle", "Build frontend assets"
def bundle_assets
  shebang :node, <<~JS
    const esbuild = require("esbuild")
    esbuild.buildSync({ entryPoints: ["src/app.js"], bundle: true, outfile: "dist/app.js" })
  JS
end
```

Supported interpreters: `:python3`, `:python`, `:node`, `:ruby`, `:perl`, `:bash`, `:sh`. Any other symbol is passed directly to `system` with a `.tmp` extension.

### Importing task modules

Split tasks into reusable modules and include them flat (all tasks in the same namespace):

```ruby
# shared/deploy_tasks.rb
module DeployTasks
  def self.included(base)
    base.desc "deploy", "Deploy to production"
    base.define_method(:deploy) { sh "cap production deploy" }
  end
end

# .loki
require_relative "shared/deploy_tasks"

class Tasks < Asgard::Base
  import DeployTasks
end
```

For namespaced subcommands, use Thor's `register`:

```ruby
register DeployTasks, "deploy", "deploy COMMAND", "Deployment tasks"
# invoked as: asgard deploy production
```

### Dotenv

```ruby
class Tasks < Asgard::Base
  dotenv          # loads .env from CWD
  dotenv ".env.local"

  desc "check", "Print the app name"
  def check
    sh "echo $APP_NAME"
  end
end
```

### Echo suppression

Pass `silent: true` to suppress the command echo (equivalent to `just`'s `@` prefix):

```ruby
def build
  sh "bundle exec rake build", silent: true   # runs quietly, output still shown
end
```

## Shell helpers

| Method | Description |
|---|---|
| `sh(script, silent: false)` | Run a shell command or multiline script |
| `shebang(interpreter, script, silent: false)` | Write script to a tempfile and execute it |

Both exit with the command's status code on failure.

## Full example `.loki`

```ruby
require "asgard"

class Tasks < Asgard::Base
  dotenv

  var :app,     "myapp"
  var :version, -> { File.read("VERSION").strip }

  desc "test", "Run the test suite"
  def test
    sh "bundle exec rake test"
  end

  depends_on :test
  desc "quality", "Run tests then check complexity"
  def quality
    sh "flog lib/"
  end

  desc "build", "Build the gem"
  def build
    sh "bundle exec rake build"
  end

  depends_on :quality, :build
  desc "release", "Release #{version} to RubyGems"
  def release
    sh "bundle exec rake release"
  end
end
```

## Development

```bash
git clone git@github.com:MadBomber/asgard.git
cd asgard
bundle install
bundle exec rake test       # run tests with coverage
bundle exec bin/asgard help # try the CLI against this gem's own .loki file
```

Coverage threshold is enforced at 95% via SimpleCov.

## Contributing

Bug reports and pull requests are welcome at https://github.com/MadBomber/asgard.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
