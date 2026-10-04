# Schedule backend

A schedule backend runs asgard tasks under one platform's own scheduler:
launchd on macOS, systemd user timers on Linux, Task Scheduler on Windows,
and crontab as the portable fallback. Each backend is a plain class with no
shared parent. The instance API they all implement is documented once, in
`lib/asgard/schedule/declaration.rb`, and `Schedule::Commands` is its only
caller.

## Obligations

- **B1** Every backend implements the whole instance API in `declaration.rb`
  (`files`, `install`, `uninstall`, `start`, `stop`, `trigger`,
  `installed_names`, `installed_entries`, `installed_columns`,
  `installed_directory`, `status`, `log_path`, `notes`), so `Commands` never
  branches on which one it has.
- **B2** A backend shells out only through the injected runner
  (`runner: Schedule.runner`), so every backend is tested on every platform
  with a recording runner.
- **B3** Everything platform-neutral (parsing a declaration, naming an entry,
  building the job's argv, the `list` columns) lives in `declaration.rb`.
  What stays in a backend is what that scheduler alone needs.

```covers
Asgard::Schedule::Launchd
Asgard::Schedule::Systemd
Asgard::Schedule::Cron
Asgard::Schedule::Windows
```
