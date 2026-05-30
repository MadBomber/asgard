# Variables

`var` declares a named value that is available to all tasks in the class as a method call. Values can be static or lazily evaluated.

---

## Static Value

Pass the value directly as the second argument:

```ruby
class Tasks
  var :app,  "myapp"
  var :env,  "production"
  var :port, 3000

  desc "Print app info"
  def info
    puts "#{app} running on port #{port} in #{env}"
  end
end
```

---

## Lazy Lambda

Pass a lambda (or proc) to defer evaluation until the variable is first accessed. The lambda is called once and its return value is used for all subsequent accesses:

```ruby
class Tasks
  var :version, -> { `git describe --tags`.strip }
  var :sha,     -> { `git rev-parse --short HEAD`.strip }

  desc "Create a release tag"
  def tag = sh "git tag v#{version}"

  desc "Show version info"
  def info = puts "#{version} (#{sha})"
end
```

!!! tip
    Lazy lambdas are ideal for values that require a shell call or file read — they only pay the cost if the variable is actually used in the task being run.

---

## Block Syntax

You can also use a block instead of a lambda:

```ruby
class Tasks
  var(:build_dir) { "builds/#{app}" }
  var(:app)       { "myapp" }

  desc "Compile into build_dir"
  def build = sh "rake build OUTDIR=#{build_dir}"
end
```

!!! note
    The block form and the lambda form behave identically — both are stored as callables and invoked on first access.

---

## Accessing Variables from Tasks

Variables are available as method calls from within any task body (or other method) in the same class. They are defined using `no_commands`, so they appear neither in `--help` output nor as CLI commands:

```ruby
class Tasks
  var :app,     "myapp"
  var :version, -> { `git describe --tags`.strip }
  var :pkg,     -> { "pkg/#{app}-#{version}.gem" }

  desc "Build the gem"
  def build = sh "gem build #{app}.gemspec"

  desc "Push the gem to RubyGems"
  def push = sh "gem push #{pkg}"
end
```

Variables can reference other variables in their lambdas as long as the referenced variable is also defined with `var` on the same class.

---

## Sharing Variables Across Files

Because all `.loki` files reopen the same `class Tasks`, variables declared in one file are available in all other files loaded in the same session:

```ruby
# config.loki
class Tasks
  var :app,  "myapp"
  var :port, 8080
end

# deploy.loki
class Tasks
  desc "Deploy the app"
  def deploy = sh "cap deploy APP=#{app} PORT=#{port}"
end
```

---

## Naming Caution

!!! warning
    Do not use `var` names that conflict with built-in Ruby method names, Thor DSL method names, or Asgard's own built-in methods. In particular, avoid naming a variable `version` — `Tasks` already defines `_version` (the `--version` flag handler), and a `var :version` would collide with that namespace and produce confusing behavior. Use a more specific name like `app_version` or `gem_version` instead.

```ruby
# Avoid this — conflicts with the built-in version infrastructure:
# var :version, -> { "1.0.0" }

# Use this instead:
var :app_version, -> { `git describe --tags`.strip }
```

Other names to avoid: `options`, `class_options`, `shell`, `invoke`, `invoke_command`.
