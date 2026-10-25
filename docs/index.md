# Asgard

<table>
<tr>
<td width="40%" align="center" valign="top">
<img src="assets/images/asgard.jpg" alt="Asgard" width="300"><br>
<em>"Loki collects the tricks.<br>Thor of Asgard runs them."</em>
</td>
<td width="60%" valign="top">
<strong>Key Features</strong>
<ul>
<li><strong>Tasks in plain Ruby</strong>: a task is a method in a <code>.loki</code> file; every Thor DSL word (<code>desc</code>, <code>method_option</code>, <code>long_desc</code>, <code>map</code>, <code>subcommand</code>) works as written</li>
<li><strong>Dependencies</strong>: <code>depends_on</code> runs prerequisites first, in sequence or in parallel stages, each at most once per run</li>
<li><strong>Shell commands</strong>: execute shell scripts through user-defined shell environments, as foreground or background processes</li>
<li><strong>Variables and helpers</strong>: <code>@@name</code> values shared by every task, <code>helper</code> methods usable in help text and task bodies alike</li>
<li><strong>Subcommands</strong>: group tasks as <code>asgard db migrate</code> or <code>asgard server start</code></li>
<li><strong>Environment</strong>: <code>dotenv</code> loads a <code>.env</code> file; <code>env(:port, "3000")</code> reads a variable with a default</li>
<li><strong>Auto-discovery</strong>: run <code>asgard</code> from any subdirectory; it finds the project's <code>.loki</code> by walking up</li>
<li><strong>Multi-file projects</strong>: split tasks across <code>*.loki</code> files and pull them in with <code>import</code></li>
<li><strong>Scheduled tasks</strong>: <code>schedule :backup, at: "02:00"</code> and <code>asgard schedule install</code> hand a task to launchd or systemd</li>
<li><strong>Watched files</strong>: <code>watch :test, paths: "lib"</code> and <code>asgard watcher start</code> run a task whenever files change</li>
<li><strong>Background jobs</strong>: <code>sh "mkdocs serve", background: true</code> starts a job that outlives asgard; <code>asgard jobs</code> lists, stops and restarts it</li>
<li><strong>Built-in flags</strong>: <code>--version</code>, <code>--debug</code>, <code>--verbose</code> and <code>--doctor</code>, which diagnoses a project's task files</li>
</ul>
</td>
</tr>
</table>

Asgard is a command-line task runner for any project. You describe the tasks a project needs (build it, test it, deploy it, serve its docs) as short Ruby methods in a file named `.loki`, and `asgard <task>` runs them. Asgard orders prerequisites for you, runs independent ones in parallel, and can keep running tasks when you are not at the keyboard: on a timer, when files change, or as a background process you manage later.

The name is a small joke: Thor is the command-line toolkit asgard is built on, Asgard is where the tasks live, and Loki, the `.loki` file, holds all the tricks.

---

## Quick Start

```bash
# Install the command
gem install asgard

# Mark your project root
cd ~/work/myproject
touch .loki

# Add a first task
cat >> .loki << 'EOF'
class Tasks
  desc "Say hello"
  def hello = puts "Hello from Asgard!"
end
EOF

# Run it
asgard hello
```

```
Hello from Asgard!
```

`asgard help` lists every task the project defines, and `asgard help hello` shows the help for one of them.

---

## How It Works

When you type `asgard build`, asgard looks for a file named `.loki` in the current directory, then in its parent, and so on up to the root of the filesystem. The first one it finds marks the project root, so the command works from any subdirectory of the project.

That `.loki` file is plain Ruby. Asgard has already defined a class named `Tasks`; your file reopens it and adds methods. Each public method with a `desc` is a task you can run from the command line:

```ruby
class Tasks
  desc "Compile the project"
  def build = sh "rake build"

  depends_on :build
  desc "Run the tests"
  def test = sh "rake test"
end
```

Only `.loki` loads on its own. When a project outgrows one file, `.loki` says what else to load with `import "*.loki"`, and every imported file reopens the same `Tasks` class.

Asgard is built on Thor, so the words you may know from other Ruby command-line tools work unchanged inside a `.loki`: `desc`, `method_option`, `class_option`, `long_desc`, `argument`, `default_task`, `map` and `subcommand`. Asgard adds its own on top: `depends_on`, `sh` and `shebang` (with `background:` for jobs), `shell`, `default_shell`, `helper`, `header`, `footer`, `dotenv`, `schedule` and `watch`.

---

## Where to Go Next

The manual is layered. Each page starts with the simplest thing that works and goes deeper from there, so you can stop reading whenever you have what you need.

Start with [Getting Started](getting-started.md), then pick from the sections below.

### Writing Tasks

| Page | What it covers |
|---|---|
| [Defining Tasks](tasks.md) | `desc`, parameters, options, `long_desc`, hidden tasks, `default_task`, aliases, exit status |
| [Shell Commands](shell.md) | `sh` and `shebang`, the `shells` registry, pinning a bash, long-running commands |
| [Dependencies](dependencies.md) | Sequential and parallel stages, run-once rules, failures, `dep_result`, computed dependency lists |
| [Options & Flags](options.md) | Per-task and class-wide options, the built-in flags, `debug?` and `verbose?` |
| [Variables](variables.md) | `@@` class variables, constants, interpolation, computed values |
| [Helper Methods](helpers.md) | `private`, `no_commands`, the `helper` DSL, sharing helpers across files |
| [Subcommands](subcommands.md) | Grouping tasks under a name such as `asgard db migrate` |

### Organizing a Project

| Page | What it covers |
|---|---|
| [Task Files](task-files.md) | The `.loki` marker, `import`, `import_up`, `loki_up`, multi-file layouts, overridden tasks |
| [Environment Variables](environment.md) | `dotenv`, `env()`, and every variable asgard sets or reads |
| [Help & Diagnostics](diagnostics.md) | `asgard help`, `asgard tree`, `header`/`footer`, the `--doctor` report, error messages and exit codes |

### Built-in Commands

| Page | What it covers |
|---|---|
| [Scheduled Tasks](schedule.md) | `schedule :task, at: ...` and `asgard schedule install`, `list`, `start`, `stop` and more, under launchd or systemd |
| [Watched Files](watch.md) | `watch :task, paths: ...`, `asgard watcher start`, `stop`, `list` and more, and `changes` inside a task |
| [Background Jobs](jobs.md) | `sh ..., background: true` and `asgard jobs list`, `stop`, `log`, `restart` and `clean` |

### Reference

| Page | What it covers |
|---|---|
| [DSL Reference](reference.md) | Every word you can write in a `.loki`, with its signature |
| [Command Reference](commands.md) | Every `asgard` command, subcommand and flag |
| [Files & Directories](files.md) | Where asgard keeps logs, state and job definitions on disk |
| [Examples](examples.md) | The working `.loki` files shipped in the repository |

[Upgrading to 0.6.0](upgrading-0.6.md) explains the changes that affect existing schedules, watchers and `sh` calls, and the [Changelog](changelog.md) has the release history.

---

## Requirements

- Ruby 3.2 or later.
- macOS or Linux for scheduled tasks and the file watcher (launchd on macOS, systemd user timers on Linux). Everything else works wherever Ruby does.
- A C++17 compiler at install time: `gem install asgard` compiles one native extension. Xcode's command-line tools or a distribution's `build-essential` package is enough.

Asgard is on [RubyGems](https://rubygems.org/gems/asgard); the source and issue tracker are on [GitHub](https://github.com/MadBomber/asgard).
