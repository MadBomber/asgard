# Shell Helpers

Asgard provides two methods for running shell commands and scripts from within task bodies: `sh` for shell commands and heredocs, and `shebang` for polyglot scripts. Both are provided by `Asgard::Shell` and mixed into every `Tasks` instance.

Both methods exit with the command's status code on failure — they do not raise Ruby exceptions.

---

## `sh` — Run Shell Commands

### Single-Line Command

Pass a single-line string to run it via `system`:

```ruby
class Tasks
  desc "build", "Compile the project"
  def build = sh "rake build"

  desc "clean", "Remove build artifacts"
  def clean = sh "rm -rf dist/ tmp/"
end
```

By default, `sh` prints the command before running it:

```
rake build
```

### Multi-Line Heredoc

Pass a multiline string (e.g., a heredoc) to run it as a single `bash -c` script. All lines execute in the same shell session, so variable assignments carry across lines:

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
end
```

Asgard detects the newline and automatically routes multiline scripts through `bash -c`.

### Silent Mode

Pass `silent: true` to suppress the command echo. The command still runs and still exits on failure; it just doesn't print the command text first:

```ruby
class Tasks
  desc "build", "Compile (quiet)"
  def build = sh "rake build", silent: true

  desc "info", "Print environment info without noise"
  def info
    sh "printenv | grep APP_", silent: true
  end
end
```

### Exit on Failure

`sh` always calls `exit($?.exitstatus)` if the command fails. There is no rescue path — a failing command terminates the `asgard` process. This is intentional: failed steps should stop the pipeline rather than silently continue.

```ruby
class Tasks
  depends_on :test
  desc "release", "Test then release"
  def release
    sh "bundle exec rake release"
    # Never reached if rake release fails
    puts "Released!"
  end
end
```

---

## `shebang` — Polyglot Scripts

`shebang` writes the script body to a tempfile with the appropriate extension and executes it with the specified interpreter. Use it to embed Python, Node.js, Ruby, Perl, or any other interpreter directly in a task:

### Python

```ruby
class Tasks
  desc "analyze", "Run Python data analysis"
  def analyze
    shebang :python3, <<~PYTHON
      import json
      data = json.load(open("results.json"))
      print(f"Total: {sum(data.values())}")
    PYTHON
  end
end
```

### Node.js

```ruby
class Tasks
  desc "bundle_assets", "Build frontend assets with esbuild"
  def bundle_assets
    shebang :node, <<~JS
      const esbuild = require("esbuild")
      esbuild.buildSync({
        entryPoints: ["src/app.js"],
        bundle: true,
        outfile: "dist/app.js"
      })
    JS
  end
end
```

### Ruby

```ruby
class Tasks
  desc "transform", "Transform data with Ruby"
  def transform
    shebang :ruby, <<~RUBY
      require "json"
      data = JSON.parse(File.read("input.json"))
      File.write("output.json", JSON.pretty_generate(data.transform_values(&:upcase)))
    RUBY
  end
end
```

### Bash

```ruby
class Tasks
  desc "provision", "Run a bash provisioning script"
  def provision
    shebang :bash, <<~BASH
      set -euo pipefail
      apt-get update
      apt-get install -y curl wget git
      echo "Provisioned at $(date)"
    BASH
  end
end
```

---

## Supported Interpreters

| Symbol | File Extension | Interpreter |
|---|---|---|
| `:python3` | `.py` | `python3` |
| `:python` | `.py` | `python` |
| `:node` | `.js` | `node` |
| `:ruby` | `.rb` | `ruby` |
| `:perl` | `.pl` | `perl` |
| `:bash` | `.sh` | `bash` |
| `:sh` | `.sh` | `sh` |
| Any other symbol | `.tmp` | Passed directly to `system` |

!!! note
    Unknown interpreter symbols get a `.tmp` extension and are passed to `system` directly. This makes it easy to use interpreters not in the table above:

    ```ruby
    shebang :lua, <<~LUA
      print("Hello from Lua!")
    LUA
    ```

### Silent Mode

`shebang` also accepts `silent: true`, though in practice the interpreter itself controls what is printed:

```ruby
def analyze
  shebang :python3, script_body, silent: true
end
```

---

## Combining `sh` and `shebang`

You can mix both in the same task:

```ruby
class Tasks
  desc "pipeline", "Run a mixed shell + Python pipeline"
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
