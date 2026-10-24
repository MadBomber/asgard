# Shell Helpers

`shebang` is the one way a task runs something that isn't Ruby. It writes the script to a tempfile and hands the file to an interpreter from the `shells` registry. Called with a script alone it uses the `default_shell`, and `sh script` is the same call. Both are provided by `Asgard::Shell` and mixed into every `Tasks` instance.

Both return `true` and exit with the command's status code on failure — they do not raise Ruby exceptions. Both accept `silent: true` to suppress the script echo, and `background:` to start the script as a [managed background job](jobs.md) instead of waiting for it.

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

`shell name, path, args: nil, ext: nil` at class level registers a shell and returns its name. A String path is split with shell quoting rules: the first word is the executable and any remaining words become arguments. A `Pathname` is one executable, taken whole, so a directory with a space in it needs no quoting. `args:` may be a String, also split, or an Array; it follows the words from the path. When `ext:` is omitted it is derived from the executable's basename, falling back to `.tmp`.

The executable is checked as the `.loki` loads. A path with a directory part must be an existing executable file, exactly as written, since nothing expands `~` or searches `PATH` for it later; a bare name must be found on `PATH` as an executable. A failing check raises `ArgumentError` naming the shell, so the problem shows at the declaration rather than as an exit 127 the first time a task runs. The seeded entries are not checked, which is why `shebang :perl` on a machine without perl fails only when it runs.

The name may be left out. A bare path registers under the executable's basename, with any options in the string parsed into `args:`, and a Symbol alone registers that name as itself from `PATH`:

```ruby
class Tasks
  shell "/usr/local/bin/bash -c -w"                  # :bash => { path: "/usr/local/bin/bash", args: ["-c", "-w"], ext: ".sh" }
  shell Pathname.new("/opt/homebrew/bin/fish")       # :fish
  shell :zsh                                         # :zsh  => { path: "zsh", args: [], ext: ".sh" }
end
```

With a name:

```ruby
class Tasks
  shell :bash,   "/opt/homebrew/bin/bash"            # pin bash 5 for sh and shebang :bash
  shell :strict, "bash -eu -o pipefail"              # options before the script
  shell :strict, "bash", args: "-eu -o pipefail"     # same entry
  shell :strict, "bash", args: %w[-eu -o pipefail]   # same entry
  shell :uv,     "uv run --script", ext: ".py"       # a wrapper, not just a binary
  shell :tool,   "'/Applications/Some App/bin/tool' -q"
  shell :tool,   Pathname.new("/Applications/Some App/bin/tool"), args: "-q"   # same entry

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

`default_shell name` at class level picks the registry entry that `sh`, and `shebang` called without a name, run. It starts as `:bash`. With no argument it returns the current name. A bare Symbol only selects; it never changes the registry, so a path pinned earlier with `shell` stays pinned.

Any other form registers first, exactly as `shell` would, then selects what it registered. A bare path registers under the executable's basename; a name with a path, `args:` or `ext:` registers that name, and the path is the name itself when only `args:` or `ext:` are given.

```ruby
class Tasks
  default_shell "/usr/local/bin/bash -c -w"                # register :bash with those options, select it
  default_shell :strict, "bash", args: "-eu -o pipefail"   # register :strict, select it
  default_shell :zsh, args: "-f"                           # path defaults to "zsh"
  default_shell :bash5, Pathname.new("/opt/homebrew/bin/bash")
end
```

Which is the same as:

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

## Long-Running Commands

A dev server or a REPL needs nothing special. The shell and the script it runs are one unit: when the script finishes the shell exits, and Ctrl-C reaches asgard, the shell and the command together, because all three share the terminal's process group.

```ruby
class Tasks
  desc "Documentation server startup"
  depends_on :doc_builder
  def doc_server = sh "mkdocs serve"

  desc "Start a REPL"
  def console = sh "bundle exec pry"
end
```

Asgard waits for the shell and exits with its status, so a command that ends on a signal exits 128 plus the signal number, the same as a shell would report.

!!! note
    Earlier versions accepted `exec: true` to replace the asgard process with the command. It was removed in 0.6.0; see [Upgrading to 0.6.0](upgrading-0.6.md#sh-and-shebang-exec-removed).

---

## Background Jobs: Three Modes

A script runs in one of three modes. Only the first two are asgard's.

| Mode | How you ask for it | The task | When asgard exits | `asgard jobs` |
|---|---|---|---|---|
| Foreground | `sh "rake build"` | Waits for the script before its next statement; a failure exits asgard | The script has already finished | Nothing to manage |
| Managed background | `sh "mkdocs serve", background: true` | Continues at once with a `Job` in hand | The job keeps running | Lists, stops, restarts and cleans it |
| Detached | `sh "mkdocs serve &"` | Continues at once with `true`; the shell has already exited | The process keeps running | Knows nothing about it |

`background: true` names the job after the calling task and a counter (`doc_server-1`); a Symbol or String names it outright (`background: :api`). The job starts in its own session with its output in a log, its pid and task are recorded, and `asgard jobs list|stop|log|restart|clean` manage it from then on, in this asgard run or any later one:

```ruby
class Tasks
  desc "Documentation server startup"
  depends_on :doc_builder
  def doc_server = sh "mkdocs serve", background: true

  desc "Bring up the development stack"
  def servers
    sh "docker compose up postgres", background: true    # servers-1
    sh "bin/rails server",            background: :api   # api
  end
end
```

A trailing `&` in the script is not a managed job. The shell detaches the process and exits, asgard reports success and keeps no record, and the process runs on with its output still in your terminal; you stop it yourself with `ps` and `kill`. Use `background:` for anything you expect to come back to. The whole story, naming rules, the commands and the files on disk are on the [Background Jobs](jobs.md) page.

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
