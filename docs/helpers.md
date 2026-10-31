# Helper Methods

Not every method in a `.loki` is a task. A method that computes a version string, wraps a repeated `sh` call or formats output is a helper: something tasks call, that nobody types on the command line. Asgard gives you three ways to write one, and this page says which to use when.

The simplest and most common is `private`:

```ruby
class Tasks
  desc "Compile and package"
  def build
    compile("src")
    package(app_version)
  end

  private

  def compile(dir)     = sh "gcc -O2 -o bin/myapp #{dir}/*.c"
  def package(ver)     = sh "tar czf pkg/myapp-#{ver}.tar.gz bin/"
  def app_version      = `git describe --tags`.strip
end
```

```bash
asgard build        # runs compile, then package
asgard compile      # Could not find command "compile".
```

!!! warning "A public method without a `desc` is a task"
    A public `def` with no `desc` above it is a *hidden* task: it does not appear in `asgard help`, but `asgard name` runs it and `depends_on :name` accepts it. A helper must therefore be `private`, sit inside a `no_commands` block, or be defined with `helper`. `asgard --doctor` lists hidden tasks, which is a quick way to find a helper that was left public by mistake.

---

## Private Methods

Everything after `private` in a class body is a private method: callable from any task in the same class, invisible to the command line and to `asgard help`:

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

`private` applies to every method defined after it in that class body, so the usual layout is tasks first, one `private`, then the helpers. A `.loki` that reopens `Tasks` later starts public again.

A helper can use everything a task can: `sh` and `shebang`, `options`, `env`, `changes`, `dep_result`, and the `@@` variables.

---

## The `no_commands` Block

`no_commands do ... end` marks the methods inside it as not being tasks, while leaving them public. Use it when a helper must stay public, for instance so a subcommand class or an included module can call it from outside:

```ruby
class Tasks
  desc "Compile the project"
  def build
    puts "Revision: #{current_sha}"
    sh "rake build"
  end

  no_commands do
    def current_sha = `git rev-parse --short HEAD`.strip
    def timestamp   = Time.now.strftime("%Y%m%d-%H%M%S")
  end
end
```

A `no_commands` block may sit anywhere in the class body, including between a `desc` and the task it describes; the `desc` still attaches to the task.

---

## The `helper` DSL Method

Some values are needed in two places: inside task bodies, and in the class body itself, where `header`, `footer` and `@@` initializers run. A plain `def` only makes a method for task bodies; a `def self.name` only makes one for the class body. `helper` defines both from one block:

```ruby
class Tasks
  @@project ||= "myapp".freeze

  helper(:version) {
    @@version ||= File.read("lib/myapp/version.rb")[/VERSION\s*=\s*"([^"]+)"/, 1].freeze
  }

  header "#{@@project} v#{version}"     # class body: used while the file loads

  desc "Show version"
  def show_version = puts version       # task body: used when the task runs
end
```

```bash
asgard help
# asgard v0.6.0 The Mighty Thor and Loki working for you
#
# myapp v1.4.0
# ...
asgard show_version
# 1.4.0
```

Without `helper`, the same thing takes two definitions:

```ruby
def self.version = File.read("lib/myapp/version.rb")[/VERSION\s*=\s*"([^"]+)"/, 1].freeze
no_commands { private def version = self.class.version }
```

### Arguments

The block takes any signature a Ruby method can: positional, keyword, defaults, a block:

```ruby
helper(:project_root) { loki_up.dirname.to_s }
helper(:gem_path)     { |name| "lib/#{name}/version.rb" }
helper(:tag_prefix)   { |sep = "-"| "#{@@project}#{sep}" }
helper(:format_version) { |name, version, prefix: "v", separator: "-"|
  "#{prefix}#{name}#{separator}#{version}"
}
```

A wrong number of arguments or an unknown keyword raises the ordinary Ruby `ArgumentError`.

### Visibility

A `helper` method never appears in `asgard help`, cannot be run from the command line, and is private inside task bodies.

### When to Use It

Use `helper` when a value is needed both while the file loads (a `header`, a `@@` default) and while a task runs. For a helper that only task bodies call, `private` is simpler.

---

## Choosing Between Them

| | `private` | `no_commands` | `helper` |
|---|---|---|---|
| Hidden from `asgard help` | Yes | Yes | Yes |
| Runnable from the command line | No | No | No |
| Usable in task bodies | Yes | Yes | Yes |
| Usable in the class body (`header`, `@@` defaults) | No | No | Yes |
| Callable from outside the class (a module, a subclass's class body) | No | Yes | Class side only |
| Looks like | Plain Ruby | Thor | Asgard |

For most helpers, `private`. Use `no_commands` when the method must stay public, and `helper` when the class body needs it too.

---

## Sharing Helpers Across Files

### A Ruby Module in the Project

Put shared helpers in a plain Ruby file as a module, load it with `require_relative`, and `include` it in `Tasks`. Methods declared `private` inside the module stay private, so they are helpers, not tasks:

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

  private

  def app_version = File.read("VERSION").strip
end
```

!!! tip
    A module method runs as part of the task, so it can call `sh`, `shebang`, `env`, `changes`, `options` and `dep_result` exactly as a method written in `Tasks` can.

### A Shared `.loki` Up the Tree

When several projects share a set of *tasks* (not just helpers), keep them in a `.loki` file in a common ancestor directory and load it with `import_up`, which finds the file without knowing how deep the project sits:

```
~/sandbox/
  shared_tasks.loki     ← tasks every project gets
  projectA/
    .loki               ← import_up "shared_tasks.loki"
  projectB/
    .loki               ← import_up "shared_tasks.loki"
```

```ruby
# projectA/.loki
import_up "shared_tasks.loki"

class Tasks
  # the shared tasks and helpers are defined by here
end
```

`import_up` returns `false` instead of failing when the file is not found, so it is safe in a project that may or may not have the shared file above it. See [Task Files](task-files.md) for `import`, `import_up` and `loki_up`.

---

## Helpers in Subcommands

A subcommand class inherits from `Tasks`, so it inherits every private helper, `no_commands` method and `helper` defined there. It can also define its own:

```ruby
class DeployCommands < Tasks
  desc "Deploy to staging"
  def staging = deploy_to("staging")

  desc "Deploy to production"
  def production = deploy_to("production")

  private

  def deploy_to(env)
    sh "cap #{env} deploy REV=#{current_sha}"   # current_sha comes from Tasks
  end
end

class Tasks
  desc "deploy SUBCOMMAND", "Deploy the application"
  subcommand "deploy", DeployCommands
end
```

See [Subcommands](subcommands.md).

---

## Names to Avoid

A helper cannot take a name that asgard or Thor use internally: `shell`, `options`, `invoke`, `run`, `args` and a few others. A `.loki` that defines one, as a task or as a helper, is refused when it loads, with the file and line. The list is in [Defining Tasks](tasks.md#reserved-names).
