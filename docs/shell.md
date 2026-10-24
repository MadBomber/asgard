# Shell Helpers

`shebang` is the one way a task runs something that isn't Ruby. It writes the script to a tempfile and hands the file to an interpreter from the `shells` registry. Called with a script alone it uses the `default_shell`, and `sh script` is the same call. Both are provided by `Asgard::Shell` and mixed into every `Tasks` instance.

Both return `true` and exit with the command's status code on failure — they do not raise Ruby exceptions. Both accept `silent: true` to suppress the script echo and `exec: true` to replace the asgard process instead of forking — see [Handing Off with `exec`](#handing-off-with-exec).

---

## `sh` — Run a Script in the Default Shell

`sh script` is `shebang script`: the script runs under the `default_shell`, which is bash until a `.loki` says otherwise. One line or many take the same path:

```ruby
class Tasks
  desc "Compile the project"
  def build = sh "rake build"

  desc "Check for a Gemfile"
  def check = sh '[[ -f Gemfile ]] && echo "found"'

  desc "Bootstrap the development environment"
  def setup
    sh <<~SHELL
      brew install redis postgresql
      brew services start redis
      bundle install
      rails db:setup
    SHELL
  end
end
```

All lines of a heredoc execute in the same shell session, so variable assignments carry across lines. By default the script is printed before it runs:

```
rake build
```

!!! note
    Earlier versions ran a one-line `sh` script through `/bin/sh` and a heredoc through `bash`. On Debian and Ubuntu `/bin/sh` is dash, so bash syntax such as `[[ ... ]]` or `$PIPESTATUS` failed in a one-liner and worked in a heredoc. Both now take the same path.

### Silent Mode

Pass `silent: true` to suppress the echo. The script still runs and still exits on failure:

```ruby
class Tasks
  desc "Compile (quiet)"
  def build = sh "rake build", silent: true
end
```

### Exit on Failure

A failing script calls `exit($?.exitstatus)`. There is no rescue path — a failing command terminates the `asgard` process. This is intentional: failed steps should stop the pipeline rather than silently continue.

```ruby
class Tasks
  depends_on :test
  desc "Test then release"
  def release
    sh "bundle exec rake release"
    # Never reached if rake release fails
    puts "Released!"
  end
end
```

---

## `shebang` — Any Interpreter

`shebang name, script` writes the script to a tempfile with the extension registered for `name` and runs the registered executable on it. Use it to embed Python, Node.js, Ruby, Perl, or any other interpreter directly in a task:

```ruby
class Tasks
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
      import * as esbuild from "esbuild"
      esbuild.buildSync({ entryPoints: ["src/app.js"], bundle: true, outfile: "dist/app.js" })
    JS
  end

  desc "Run a bash provisioning script"
  def provision
    shebang :bash, <<~BASH
      set -euo pipefail
      apt-get update
      apt-get install -y curl wget git
    BASH
  end
end
```

A name that isn't registered runs as itself, found on `PATH`, with a `.tmp` extension. So any interpreter works without declaring it:

```ruby
shebang :lua, <<~LUA
  print("Hello from Lua!")
LUA
```

If the executable can't be found, asgard prints the shell name and the command it tried, then exits 127:

```
asgard: shell :lua not found: lua ...
```

---

## The `shells` Registry

`Tasks.shells` is a Hash from shell name to the executable, the arguments placed before the script, and the tempfile extension. It is seeded with:

| Name | `path` | `args` | `ext` |
|---|---|---|---|
| `:bash` | `bash` | `[]` | `.sh` |
| `:sh` | `sh` | `[]` | `.sh` |
| `:python3` | `python3` | `[]` | `.py` |
| `:python` | `python` | `[]` | `.py` |
| `:node` | `node` | `[]` | `.js` |
| `:ruby` | `ruby` | `[]` | `.rb` |
| `:perl` | `perl` | `[]` | `.pl` |

```ruby
Tasks.shells[:bash]   # => { path: "bash", args: [], ext: ".sh" }
```

A bare `path` is looked up on `PATH` each time the script runs, exactly as the kernel does for a `#!/usr/bin/env` line. The extension matters only to interpreters that read it: Node decides between CommonJS and ES modules by extension, and PowerShell refuses a file that isn't `.ps1`.

### `shell` — Add or Replace an Entry

`shell name, path, args: nil, ext: nil` at class level registers a shell. The path string is split with shell quoting rules: the first word is the executable and any remaining words become arguments. `args:` may be a String, also split, or an Array; it follows the words from the path. When `ext:` is omitted it is derived from the executable's basename, falling back to `.tmp`.

```ruby
class Tasks
  shell :bash,   "/opt/homebrew/bin/bash"            # pin bash 5 for sh and shebang :bash
  shell :strict, "bash -eu -o pipefail"              # options before the script
  shell :strict, "bash", args: "-eu -o pipefail"     # same entry
  shell :strict, "bash", args: %w[-eu -o pipefail]   # same entry
  shell :uv,     "uv run --script", ext: ".py"       # a wrapper, not just a binary
  shell :tool,   "'/Applications/Some App/bin/tool' -q"

  desc "Deploy under strict bash"
  def deploy = shebang :strict, <<~BASH
    cd build
    rsync -a . server:/srv/app/
  BASH
end
```

```ruby
Tasks.shells[:strict]  # => { path: "bash", args: ["-eu", "-o", "pipefail"], ext: ".sh" }
```

There is one registry for every `Tasks` subclass, so a `shell` declared in `.loki` applies inside subcommand classes too.

### `default_shell` — What `sh` Runs

`default_shell name` at class level picks the registry entry that `sh`, and `shebang` called without a name, run. It starts as `:bash`. With no argument it returns the current value.

```ruby
class Tasks
  shell :strict, "bash -eu -o pipefail"
  default_shell :strict

  desc "Every sh call now runs under strict bash"
  def build
    sh "rake build"              # shebang :strict, "rake build"
    shebang "rake package"       # same shell, same path
    shebang :python3, "print('explicit names still win')"
  end
end
```

Like the registry, the default is one value shared by every `Tasks` subclass.

### Pinning a Path

Your terminal's `PATH` and the `PATH` a scheduled or watched task sees are not the same. On a Mac with Homebrew, `bash` at the terminal is 5.x from `/opt/homebrew/bin`, while under `launchd` it is the 3.2 build in `/bin`. Pin the one you mean:

```ruby
shell :bash, "/opt/homebrew/bin/bash"
```

A `.loki` file is Ruby, so a path that differs between machines is an ordinary expression:

```ruby
shell :bash, %w[/opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash].find { File.executable?(it) }
```

---

## Handing Off with `exec`

Pass `exec: true` to hand the command the asgard process itself instead of forking a child. Under the hood this calls `Kernel.exec` rather than `system`, which replaces the running ruby process image with the command — asgard doesn't stick around waiting on it.

Use this for a task's final, long-running command — a dev server, a REPL, anything meant to take over the terminal — so there's no idle ruby process sitting in memory alongside it, and Ctrl-C is handled directly by the command instead of unwinding back through asgard:

```ruby
class Tasks
  desc "Documentation server startup"
  depends_on :doc_builder
  def doc_server = sh "mkdocs serve", exec: true

  desc "Start a REPL — never returns to asgard"
  def console
    sh "bundle exec pry", exec: true
    puts "unreachable"
  end
end
```

Since the process is replaced, nothing after the call ever runs, and `depends_on` chains upstream of it must already have finished (they have — dependencies run before the task body).

No process survives an `exec` to delete the tempfile, so asgard unlinks it before the hand-off and passes the interpreter the still-open descriptor as `/dev/fd/N`. Nothing is left behind in the temp directory. The one consequence is that the interpreter sees no file extension, so a Node script written as an ES module should not use `exec: true`.

!!! note
    `exec: true` only makes sense for a command meant to run for the lifetime of the process. Don't use it for a step with more work queued after it in the same task.

---

## Combining `sh` and `shebang`

Mix both freely in the same task:

```ruby
class Tasks
  desc "Run a mixed shell + Python pipeline"
  def pipeline
    sh "bundle exec rake build"

    shebang :python3, <<~PYTHON
      import subprocess
      result = subprocess.run(["./bin/validate"], capture_output=True, text=True)
      print(result.stdout)
    PYTHON

    sh "rake deploy"
  end
end
```
