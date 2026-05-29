# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-05-28
### Added

- Parallel dependency execution — wrap deps in an array to run them concurrently:
  `depends_on [:build, :lint]` or `depends_on :setup, [:build, :lint], :deploy`
- `Asgard.run!(argv)` — single entry point encapsulating find, load, validate, and start
- `Asgard.load_loki(dir)` — auto-loads all `*.loki` files in a directory alphabetically
- `Tasks` class pre-defined by the gem (`class Tasks < Asgard::Base`) — task files reopen it without restating the superclass
- `lib/asgard/tasks.rb` — ships the pre-defined `Tasks` class

### Changed

- Replaced `SimpleFlow` dependency with `Dagwood` — purpose-built DAG library with no extra dependencies and no Ruby 4 compatibility issues
- `bin/asgard` simplified to two lines: `require "asgard"` + `Asgard.run!(ARGV)`
- Task file convention: `.loki` is the project root marker and entry point; `*.loki` files each reopen `class Tasks` and are auto-loaded before `.loki`
- `Asgard.find_task_files` renamed to `Asgard.find_task_file` (singular — only `.loki` is the entry point)
- `depends_on` now accepts mixed sequential/parallel stages; bare symbols run sequentially, arrays within the splat run in parallel
- `run!` handles its own errors — missing `.loki` and circular dependencies produce a clean one-line message and exit 1 rather than a backtrace
- Thread-safe dep deduplication via class-level `_ran_tasks` Set + Mutex replaces Thor's `@_invocations`
- Removed `import` macro — task files use Ruby class reopening instead of modules

### Removed

- `SimpleFlow` dependency (replaced by `Dagwood`)
- `logger` gem workaround (was only needed for SimpleFlow on Ruby 4)
- `*.loki` glob fallback in `find_task_file` — only `.loki` is the auto-discovered entry point

## [0.1.0] - 2026-05-28

### Added

- `Asgard::Base` — Thor subclass providing the task DSL
- `depends_on` — declare recipe dependencies; dependencies run at most once per invocation
- `var` — declare static or lazy-evaluated variables available to all recipes
- `import` — flat-merge a task module into the current class
- `dotenv` — load a `.env` file into the environment
- `sh` — run a shell command or multiline heredoc script; exits with the command's status on failure
- `shebang` — write a script body to a tempfile and execute it with a given interpreter (`:python3`, `:node`, `:ruby`, `:perl`, `:bash`, `:sh`, or any custom interpreter)
- `Asgard.find_task_files` — search current directory and ancestors for task files
- Task file resolution: `.loki` takes priority; falls back to all `*.loki` files sorted alphabetically
- `asgard` executable — finds task files, validates dependency graph, dispatches via Thor
- Circular dependency detection via `SimpleFlow::DependencyGraph` at startup
- 100% test coverage enforced via SimpleCov (95% minimum threshold)
- Quality task in `.loki` runs flog after tests

[Unreleased]: https://github.com/MadBomber/asgard/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/MadBomber/asgard/releases/tag/v0.1.0
