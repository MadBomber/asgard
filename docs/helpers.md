# Helper Methods

Not every method needs to be a CLI command. Asgard (via Thor) provides two mechanisms to define callable helper methods that are excluded from `asgard help` and cannot be invoked directly from the command line.

---

## Private Methods

Methods declared after `private` are callable from any task in the same class but are invisible to Thor's command dispatcher. They will not appear in `--help` output and cannot be called from the CLI:

```ruby
class Tasks
  desc "Compile and package"
  def build
    compile("src")
    package(app_version)
  end

  desc "Build and publish to RubyGems"
  def release
    build
    sh "gem push pkg/myapp-#{app_version}.gem"
  end

  private

  def compile(dir)
    sh "gcc -O2 -o bin/myapp #{dir}/*.c"
  end

  def package(ver)
    sh "tar czf pkg/myapp-#{ver}.tar.gz bin/"
  end

  def app_version
    `git describe --tags`.strip
  end
end
```

!!! note
    In Ruby, `private` applies to all methods defined after it in the same class body. You can group all helpers at the bottom of the class after a single `private` declaration.

---

## The `no_commands` Block

Thor's `no_commands` block marks public methods as excluded from CLI discovery. Unlike `private`, these methods are still publicly accessible from Ruby code (e.g., from a subclass or a module). They are useful for methods that must be public for technical reasons but should not appear as commands:

```ruby
class Tasks
  desc "Compile the project"
  def build
    puts "Revision: #{current_sha}"
    sh "rake build"
  end

  desc "Deploy to production"
  def deploy
    puts "Deploying revision #{current_sha}..."
    sh "cap production deploy"
  end

  no_commands do
    def current_sha
      `git rev-parse --short HEAD`.strip
    end

    def timestamp
      Time.now.strftime("%Y%m%d-%H%M%S")
    end
  end
end
```

`var`-declared variables are also implemented using `no_commands` internally, which is why they appear as callable methods but not as CLI commands.

---

## Choosing Between `private` and `no_commands`

| | `private` | `no_commands` |
|---|---|---|
| Hidden from `--help` | Yes | Yes |
| Blocked from CLI | Yes | Yes |
| Accessible from subclass | No | Yes |
| Accessible from module include | No | Yes |
| Ruby idiom | Familiar | Thor-specific |

For most helpers, `private` is the right choice. Use `no_commands` when the helper must remain technically public (e.g., it will be inherited by a subcommand class).

---

## Sharing Helpers Across Files

Extract shared helpers into a plain Ruby module and load it from `.loki` using `require_relative`:

```ruby
# shared/helpers.rb
module BuildHelpers
  private

  def compile(dir)
    sh "gcc -O2 -o bin/myapp #{dir}/*.c"
  end

  def dist_path(ver)
    "pkg/myapp-#{ver}.tar.gz"
  end
end
```

```ruby
# .loki
require_relative "shared/helpers"

class Tasks
  include BuildHelpers

  desc "Compile the project"
  def build = compile("src")

  desc "Create distribution archive"
  def package = sh "tar czf #{dist_path(app_version)} bin/"
end
```

Because `include` in the class body makes the module methods available as instance methods, and they are declared `private` inside the module, they remain invisible to Thor.

!!! tip
    Helpers in a shared module can call `sh`, `shebang`, and other Asgard DSL methods because those are included in `Tasks` (via `Asgard::Base` and `Asgard::Shell`) and are available in `self` when the module method is invoked.

---

## Helper Methods in Subcommands

Subcommand classes that inherit from `Tasks` also inherit all private helpers and `no_commands` methods defined on `Tasks`. You can also define helpers local to the subcommand class:

```ruby
class DeployCommands < Tasks
  desc "Deploy to staging"
  def staging = deploy_to("staging")

  desc "Deploy to production"
  def production = deploy_to("production")

  private

  def deploy_to(env)
    sh "cap #{env} deploy REV=#{current_sha}"
  end
  # current_sha is inherited from Tasks if defined there
end
```
