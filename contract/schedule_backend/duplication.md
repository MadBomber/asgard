# Duplication the schedule backends keep

## Backends stay independent

Each backend is a complete, self-contained adapter for one scheduler. They
read and write different files in different directories, with different
name prefixes and extensions, and they drive different tools (launchctl,
systemctl, crontab, schtasks). The same few shapes recur in every one of
them: the constructor that keeps the project, root and runner and picks a
data directory from the environment; the `run!` wrapper that turns a failed
command into a `Schedule::Error`; `installed_entries`, which globs a
directory and splits file names back into `[project, name]`; and
`installed_directory`, which reads the job's working directory back from its
file.

They stay parallel on purpose. A shared base class or mixin would make every
backend depend on the one file that none of their platforms need, and a
change for one scheduler would have to be re-verified against three others.
Each backend is small enough to read whole, and a reader fixing launchd
should never have to open systemd. New platform behaviour is added to one
backend; anything that turns out to be platform-neutral moves to
`declaration.rb`, not to a base class.

```parallel
Asgard::Schedule::Launchd
Asgard::Schedule::Systemd
Asgard::Schedule::Cron
Asgard::Schedule::Windows
```
