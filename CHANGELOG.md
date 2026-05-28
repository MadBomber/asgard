# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-28

### Added

- `Asgard::Base` — Thor subclass providing the task DSL
- `depends_on` — declare recipe dependencies resolved via `SimpleFlow::DependencyGraph`; dependencies run at most once per invocation
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
