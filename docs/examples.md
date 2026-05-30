# Examples

The `examples/` directory in the Asgard repository contains complete, working `.loki` files that demonstrate every feature of the gem. You can use them as a standalone Asgard project or as copy-paste references.

---

## Using the Examples Directory

The `examples/` directory contains its own `.loki` root marker (the gem's project-level `.loki`), which means you can run `asgard` from inside the `examples/` directory and all example files will be loaded:

```bash
git clone https://github.com/MadBomber/asgard.git
cd asgard/examples
asgard help
```

Alternatively, copy individual example files into your own project's directory.

!!! note
    Some examples (notably `concurrent.loki`) produce visible interleaved output to demonstrate real thread concurrency. They are designed to be run, not just read.

---

## `kitchen_sink.loki`

**Path:** `examples/kitchen_sink.loki`

The most comprehensive example — demonstrates every Thor DSL feature available in Asgard:

- `var` with a static value and a lazy lambda
- `dotenv` (commented out, ready to activate)
- `class_option` with `:boolean` and `:string` types, including `enum`
- `default_task` — sets the default command when `asgard` is run with no arguments
- `map` — short aliases for multiple tasks
- A basic task with no parameters
- A task with a positional parameter and default
- A task with `option` (the `method_option` alias)
- All five `method_option` types: `:string`, `:boolean`, `:numeric`, `:array`, `:hash`
- `required` option, `enum` validation, and `banner` customization
- `long_desc` with `\x5` line-break trick for formatted examples in help text
- Sequential `depends_on` (`:analyze` before `:spec`)
- Parallel `depends_on` (`[:analyze, :typecheck]` run concurrently)
- Mixed sequential + parallel `depends_on` (`:check`, `[:compile, :spec]`, `:pack`)
- `no_commands` block for a public helper excluded from CLI
- `private` methods for internal helpers

```bash
asgard help                # see all tasks
asgard greet               # default task
asgard hello Alice
asgard compile --jobs 4 --tags debug release --defines VERSION:2 MODE:fast
asgard deploy --strategy rolling
asgard report --format html --since 2024-01-01
asgard pipeline
```

---

## Server Subcommands

**Path:** `examples/server_subcommands.loki`

Demonstrates Thor subcommands with a server management group. Covers:

- Defining a subcommand class (`ServerCommands < Tasks`)
- Registering it with `subcommand "server", ServerCommands`
- Per-command options (`--daemon`, `--workers`, `--log`, `--force`, `--wait`)
- `depends_on` inside a subcommand group (`:stop` and `:start` before `:restart`)

```bash
asgard server help
asgard server start
asgard server start 4000 --workers 4 --daemon
asgard server stop --force
asgard server status
asgard server restart 4000
```

The `ServerCommands` class inherits from `Tasks`, giving it access to `sh`, `depends_on`, and the built-in `--debug`/`--verbose` flags.

---

## DB Subcommands

**Path:** `examples/db_subcommands.loki`

Demonstrates subcommands with more complex `depends_on` chaining within the group. Covers:

- `DBCommands < Tasks` with migrate, rollback, seed, reset, console, and status commands
- Multi-step `depends_on` chain: `rollback → migrate → seed → reset`
- `long_desc` with formatted examples inside a subcommand class
- `enum` validation on subcommand options
- Optional positional parameters (`migrate [VERSION]`, `rollback [STEPS]`, `seed [FILE]`)

```bash
asgard db help
asgard db migrate
asgard db migrate 20240101120000 --dry-run
asgard db rollback
asgard db rollback 3
asgard db seed --env staging
asgard db reset         # rollback → migrate → seed → reset
asgard db console --env staging
asgard db status
```

---

## `concurrent.loki`

**Path:** `examples/concurrent.loki`

A focused demonstration of true concurrent execution via parallel `depends_on` groups:

- Three worker tasks (`worker_a`, `worker_b`, `worker_c`) each print a character repeatedly with random sleep delays
- All three run in parallel threads when `asgard finish` is invoked
- The interleaved output proves that real concurrency is occurring (not sequential batching)
- Uses `$stdout.sync = true` to ensure thread-safe immediate output flushing

```bash
asgard finish
# starting demo of concurrent task execution ...
# ABCBACBACBABCBACBACB   (order varies every run)
# fini - the end of concurrent task demo
```

Execution order: `start` → `worker_a ∥ worker_b ∥ worker_c` → `finish`

This example is also useful as a test harness for verifying that parallel execution is working correctly on a given system.

---

## Summary

| File | Primary Focus |
|---|---|
| `kitchen_sink.loki` | Comprehensive Thor DSL reference — options, aliases, long_desc, depends_on |
| `server_subcommands.loki` | Subcommand groups, per-command options, depends_on in subcommands |
| `db_subcommands.loki` | Multi-step depends_on chains, enum validation, long_desc in subcommands |
| `concurrent.loki` | Parallel task execution, thread concurrency demonstration |
