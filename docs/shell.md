# Shell Commands

Some asgard tasks need to run processes that are not executed in Ruby: a build, a test suite, a deploy script, a Python one-off. Asgard gives every task one method for that, under two names: `sh` and `shebang` are the same method, and everything on this page about one is true of the other. `sh :python3, script` runs the script under the interpreter registered as `:python3`; `sh script`, with no shell named, runs it under the default shell. Many task authors write `sh` without a shell designation as the short-cut for an ordinary shell command and reserve the longer `shebang` for scripts in another language, which is how this page is laid out, but that is a habit, not a rule.

Whichever spelling you use, the script is written to a temporary file, run, and asgard stops if it fails, so a pipeline of tasks never continues past a broken step.

Start with the nameless form. Everything else on this page is a refinement of it.

---

## `sh`: Run a Script in the Default Shell

`sh` takes a script and runs it. One line or many, it works the same way:

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

```bash
asgard build
```

```
rake build
... rake's output ...
```

The script is printed before it runs, so the terminal shows what asgard did. All lines of a heredoc run in one shell session, so a variable set on one line is visible on the next:

```ruby
desc "Tag the build"
def tag
  sh <<~SHELL
    version=$(cat VERSION)
    git tag "v$version"
    echo "tagged v$version"
  SHELL
end
```

The shell is bash until a `.loki` says otherwise (see [`default_shell`](#default_shell-the-shell-used-when-none-is-named)). Bash syntax such as `[[ ... ]]`, arrays and `$PIPESTATUS` works in a one-liner as well as in a heredoc.

!!! note
    Before 0.6.0 a one-line `sh` went through `/bin/sh` and a heredoc through bash, so bash syntax passed or failed depending on line count. Both now take the same path. See [Breaking Changes](breaking-changes.md#sh-and-shebang-every-script-runs-under-the-default-shell).

### Silent Mode

Pass `silent: true` to skip the echo. The script still runs and still stops asgard on failure:

```ruby
desc "Compile (quiet)"
def build = sh "rake build", silent: true
```

### Exit on Failure

When the script exits non-zero, asgard exits with that same status. Nothing after the failing `sh` runs, no Ruby exception is raised, and there is nothing to rescue:

```ruby
class Tasks
  depends_on :test
  desc "Test then release"
  def release
    sh "bundle exec rake release"
    puts "Released!"        # never reached if rake release fails
  end
end
```

```bash
asgard release; echo "exit $?"
# ... rake release fails with status 1 ...
# exit 1
```

A command that ends on a signal exits with 128 plus the signal number, the way a shell reports it. This is deliberate: a task runner that continued past a failed step would hide the failure. When a command is allowed to fail, say so in the script or in Ruby:

```ruby
desc "Remove build output, if any"
def clean
  sh "rm -r dist || true"                  # the shell swallows the failure
end

desc "Report whether the server is up"
def ping
  if system("curl -fsS localhost:3000/health > /dev/null")   # plain Ruby: returns true or false
    puts "up"
  else
    puts "down"
  end
end

desc "Count TODO comments"
def todos
  count = `grep -r TODO lib | wc -l`.strip   # backticks capture output, never exit asgard
  puts "#{count} TODOs"
end
```

`sh` returns `true` when the script succeeds, which is useful at the end of an endless-method task: `def build = sh "rake build"`.

---

## `shebang`: Any Interpreter

`shebang :name, script` writes the script to a tempfile with the extension registered for `name` and runs the registered executable on it. Python, Node, Ruby, Perl or anything else can live directly in a task:

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

`shebang` is the same method as `sh`, so it takes the same `silent:` and `background:` keywords, echoes the script the same way, and exits asgard on failure the same way. `sh :python3, script` and `shebang :python3, script` are one call; so are `shebang "rake build"` and `sh "rake build"`.

### Interpreters You Did Not Register

A name that is not in the registry runs as itself, found on `PATH`, with a `.tmp` file extension (zsh, fish, csh and tcsh get their usual extensions instead; see [the registry](#the-shells-registry)). Any interpreter works without declaring it:

```ruby
desc "Say hello from Lua"
def lua_hello = shebang :lua, 'print("Hello from Lua!")'
```

If the executable is not found, asgard names the shell and the command it tried, then exits 127:

```
asgard: shell :lua not found: lua ...
```

Register the interpreter with [`shell`](#shell-add-or-replace-an-entry) when it needs a specific extension or options, or when you want the mistake caught while the `.loki` loads rather than the first time the task runs.

---

## The `shells` Registry

Every shell name maps to an executable, the arguments placed before the script file, and the tempfile extension. The registry starts with these entries:

| Name | Executable | Arguments | Extension |
|---|---|---|---|
| `:bash` | `bash` | none | `.sh` |
| `:sh` | `sh` | none | `.sh` |
| `:python3` | `python3` | none | `.py` |
| `:python` | `python` | none | `.py` |
| `:node` | `node` | none | `.js` |
| `:ruby` | `ruby` | none | `.rb` |
| `:perl` | `perl` | none | `.pl` |

You can read an entry back in a `.loki`:

```ruby
Tasks.shells[:bash]   # => { path: "bash", args: [], ext: ".sh" }
```

A bare executable such as `bash` is looked up on `PATH` each time a script runs, exactly as a `#!/usr/bin/env bash` line would do. The extension matters only to interpreters that read it: Node decides between CommonJS and ES modules by extension, and PowerShell refuses a script that is not `.ps1`. Zsh and fish scripts get `.sh` and `.fish` even without a registry entry, and csh and tcsh get `.csh`.

There is one registry for the whole project. A `shell` declared in `.loki` applies inside [subcommand classes](subcommands.md) too.

### `shell`: Add or Replace an Entry

`shell` at class level registers a shell and returns its name. The simplest forms name the shell and give its path:

```ruby
class Tasks
  shell :bash,   "/opt/homebrew/bin/bash"           # pin bash 5 for sh and shebang :bash
  shell :strict, "bash -eu -o pipefail"             # options before the script
  shell :uv,     "uv run --script", ext: ".py"      # a wrapper command, not just a binary
  shell :fish                                       # fish from PATH, defaults

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

The path string is split the way a shell splits a command line, quotes respected: the first word is the executable and the rest become arguments. `args:` adds more arguments, as a String (also split) or an Array; they follow the words from the path. `ext:` sets the tempfile extension; when omitted it comes from the executable's basename (`.sh` for bash, `.py` for python3, and so on), falling back to `.tmp`.

These are all the same entry:

```ruby
shell :strict, "bash -eu -o pipefail"
shell :strict, "bash", args: "-eu -o pipefail"
shell :strict, "bash", args: %w[-eu -o pipefail]
```

**Leaving the name out.** A bare path registers under the executable's basename, with any options parsed into the arguments:

```ruby
shell "/usr/local/bin/bash -c -w"      # :bash => { path: "/usr/local/bin/bash", args: ["-c", "-w"], ext: ".sh" }
shell Pathname.new("/opt/homebrew/bin/fish")   # :fish
```

**Paths with spaces.** A `Pathname` is one executable, taken whole and never split, so a directory with a space in it needs no quoting:

```ruby
shell :tool, "'/Applications/Some App/bin/tool' -q"                           # quoted String
shell :tool, Pathname.new("/Applications/Some App/bin/tool"), args: "-q"      # same entry, no quoting
```

**The executable is checked as the `.loki` loads.** A path with a directory part must be an existing executable file, exactly as written (nothing expands `~` or searches `PATH` for it later). A bare name must be found on `PATH`. A failing check stops the load with a message naming the shell:

```
asgard: /proj/.loki:3: shell :bash: /opt/homebrew/bin/bash is not an executable file (ArgumentError)
asgard: /proj/.loki:4: shell :uv: uv is not an executable on PATH (ArgumentError)
```

This is why a typo in a `shell` line shows at startup, while a missing seeded interpreter (`shebang :perl` on a machine without perl) shows only when the task runs: the seeded entries are not checked until they are used.

### `default_shell`: The Shell Used When None Is Named

`default_shell` picks the registry entry that `sh` and `shebang` run when no shell is named. It starts as `:bash`. With no argument it returns the current name.

A bare Symbol only selects. It checks that the shell exists but never changes the registry, so a path pinned earlier with `shell` stays pinned:

```ruby
class Tasks
  shell :strict, "bash -eu -o pipefail"
  default_shell :strict

  desc "Every call that names no shell now runs under strict bash"
  def build
    sh "rake build"              # no shell named: runs under :strict
    shebang "rake package"       # same shell, same path
    shebang :python3, "print('an explicit name still wins')"
  end
end
```

Any other form registers first, exactly as `shell` would, then selects what it registered:

```ruby
class Tasks
  default_shell "/usr/local/bin/bash -c -w"                # register :bash with those options, select it
  default_shell :strict, "bash", args: "-eu -o pipefail"   # register :strict, select it
  default_shell :zsh, args: "-f"                           # path defaults to the name, "zsh"
  default_shell :bash5, Pathname.new("/opt/homebrew/bin/bash")
end
```

Like the registry, the default is one value for the whole project, subcommands included. A `.loki` that imports several files should set it once, in the root `.loki`, before the imports.

### Pinning a Path

Your terminal's `PATH` and the `PATH` a [scheduled](schedule.md) or [watched](watch.md) task sees are not the same. On a Mac with Homebrew, `bash` at the terminal is 5.x from `/opt/homebrew/bin`, while a job started by launchd finds the 3.2 build in `/bin`. A script that uses associative arrays or `${var,,}` works in one and fails in the other. Pin the one you mean:

```ruby
shell :bash, "/opt/homebrew/bin/bash"
```

A `.loki` is Ruby, so a path that differs between machines is an ordinary expression:

```ruby
shell :bash, %w[/opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash].find { File.executable?(it) }
```

---

## Long-Running Commands

A dev server, a REPL or a watch loop needs nothing special. Asgard waits for the shell, the shell waits for the command, and Ctrl-C reaches all three at once because they share the terminal's process group:

```ruby
class Tasks
  desc "Serve the documentation"
  depends_on :doc_builder
  def doc_server = sh "mkdocs serve"

  desc "Start a REPL"
  def console = sh "bundle exec pry"
end
```

```bash
asgard doc_server
# ... Ctrl-C ...
# asgard exits 130
```

Asgard exits with the shell's status, so a command that ends on a signal exits 128 plus the signal number.

A signal sent to asgard alone also reaches the command. `timeout`, a CI runner cancelling a job, or `kill -TERM <asgard pid>` signal only asgard's own process, not the group; asgard passes the INT or TERM on to the running script, waits for it to end, and exits 130 or 143. Nothing is left running behind it.

!!! note
    Earlier versions accepted `exec: true` to replace the asgard process with the command. It was removed in 0.6.0 and now raises `ArgumentError (unknown keyword: :exec)`; delete the keyword. See [Breaking Changes](breaking-changes.md#sh-and-shebang-exec-removed).

### `$0` Is a Tempfile

Because the script runs from a file, `$0` inside it is the path of that tempfile, such as `/var/folders/.../T/asgard_20261024-80545-bmbloc.sh`, and the file is deleted when the script ends. A usage message that printed `$0` should print a name you choose instead.

---

## Three Ways a Script Runs

A script runs in one of three modes. The first two are asgard's; the third belongs to the shell.

| Mode | How you ask for it | The task | When asgard exits | `asgard jobs` |
|---|---|---|---|---|
| Foreground | `sh "rake build"` | Waits for the script before its next statement; a failure exits asgard | The script has already finished | Nothing to manage |
| Managed background | `sh "mkdocs serve", background: true` | Continues at once with a job object in hand | The job keeps running | Lists, stops, restarts and cleans it |
| Detached | `sh "mkdocs serve &"` | Continues at once with `true`; the shell has already exited | The process keeps running | Knows nothing about it |

`background: true` names the job after the calling task plus a counter (`doc_server-1`); a Symbol or String names it outright (`background: :api`). The job starts in its own session with its output in a log file, its pid and task are recorded, and `asgard jobs list|stop|log|restart|clean` manage it from then on, in this asgard run or any later one:

```ruby
class Tasks
  desc "Serve the documentation"
  depends_on :doc_builder
  def doc_server = sh "mkdocs serve", background: true

  desc "Bring up the development stack"
  def servers
    sh "docker compose up postgres", background: true    # servers-1
    sh "bin/rails server",            background: :api   # api
  end
end
```

```bash
asgard doc_server
```

```
mkdocs serve
started doc_server-1 (pid 48213), log: /Users/you/.local/state/asgard/jobs/asgard-5d41402a/doc_server-1.log
```

A trailing `&` in a script is not a managed job. The shell detaches the process and exits, asgard reports success and keeps no record, and the process runs on with its output still in your terminal. You stop it yourself with `ps` and `kill`. Use `background:` for anything you expect to come back to. The whole story, including naming rules, the commands and the files on disk, is on the [Background Jobs](jobs.md) page.

---

## Combining `sh` and `shebang`

Mix both freely in one task. Each call runs to completion before the next starts:

```ruby
class Tasks
  desc "Run a mixed shell and Python pipeline"
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

Because every call stops asgard on failure, the Python step never runs after a failed build and the deploy never runs after failed validation. To share values between steps, write them to a file or an environment variable in the script, or compute them in Ruby and interpolate them into the next script (see [Variables](variables.md#strings-and-interpolation)).

---

## `sh` Versus Ruby's Own Methods

A `.loki` is Ruby, so everything Ruby offers for running a program works in a task: `system`, backticks, `%x()`, `exec`, `spawn`, `Open3.capture3`. Nothing stops you using them, and the examples above do. What `sh` and `shebang` add is the behaviour a task runner needs around the command:

| | `sh` / `shebang` | `system` | Backticks |
|---|---|---|---|
| Shows the command before running it | Yes, unless `silent: true` | No | No |
| On failure | Exits asgard with the command's status; nothing after it runs | Returns `false` and the task carries on | Returns the output and the task carries on |
| Missing interpreter | Prints which shell and exits 127 | Returns `nil` | Raises `Errno::ENOENT` |
| Ended by a signal | Exits 128 plus the signal number | Returns `false` | Returns partial output |
| Which shell runs it | The one registered in `shells`, the same under the watcher and a schedule | `/bin/sh`, or none for a single word | `/bin/sh` |
| One line or a heredoc | The same path either way | A heredoc runs as one `/bin/sh` script | Same |
| Other interpreters | `shebang :python3, script` | Build the argv yourself | Same |
| As a managed background job | `background: true` | No | No |
| Returns | `true`, or a job object | `true`, `false` or `nil` | The command's stdout |

The first two rows are the reason to prefer `sh` by default. A task that calls `system("rake test")` and does not check the return value continues to the release step whether the tests passed or not, and asgard exits 0. The same line as `sh "rake test"` stops at the failure and exits with rake's status, and the log shows which command it was. Under the [watcher](watch.md) and a [schedule](schedule.md), where nobody is watching the terminal, both matter more.

The shell row is the other one worth knowing. `system` and backticks go through `/bin/sh`, which is dash on Debian and Ubuntu and bash 3.2 in POSIX mode on macOS, so bash syntax that works at your prompt may not work there. `sh` runs the `:bash` entry of the `shells` registry, and `shell :bash, "/opt/homebrew/bin/bash"` pins it to one executable for every run on the machine.

Ruby's methods are still the right tool when you want the output as a value, or when a failure is information rather than an error:

```ruby
desc "Tag the release"
def tag
  version = `git describe --tags --abbrev=0`.strip     # capture: backticks
  sh "git tag #{version.succ} && git push --tags"      # act: sh
end

desc "Report whether the server is up"
def ping
  puts system("curl -fsS localhost:3000/health > /dev/null") ? "up" : "down"   # false is an answer, not a failure
end
```

`sh` never captures output: the script's stdout and stderr go straight to yours, or to the watcher, schedule or job log. To use a command's output in Ruby, use backticks or `Open3`; to run a step that must succeed, use `sh`.

---

## Summary

| Call | What it runs | Notes |
|---|---|---|
| `sh "script"` | The default shell (`:bash` until changed) | One line or heredoc; echoes; exits asgard on failure |
| `sh "script", silent: true` | Same | No echo |
| `sh "script", background: true` | Same, as a managed job | Returns at once; see [Background Jobs](jobs.md) |
| `sh :name, "script"` | The shell registered as `:name` | Unregistered names run from `PATH` with `.tmp` (`.sh`, `.fish` or `.csh` for zsh, fish, csh and tcsh) |
| `shebang ...` | Exactly as `sh` | The same method under its longer name |
| `shell :name, "path", args:, ext:` | Class level: register a shell | Executable checked at load; returns the name |
| `default_shell :name` | Class level: select the default | Other forms register and select |

The full signatures are in the [DSL Reference](reference.md).
