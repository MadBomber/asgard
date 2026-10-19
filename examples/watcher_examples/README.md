# Watcher example

A small project whose tasks run when its files change. The `.loki` here
declares four watches; `lib/`, `bin/`, `docs/` and `data/` hold one
placeholder file each so the watcher has something to watch right away.

## Before you start

The watcher runs its daemon and every triggered task as separate `asgard`
processes. If you are running asgard from a git checkout of this
repository rather than an installed gem, install the checkout as the gem
first, from the repository root:

```bash
asgard install        # builds pkg/asgard-<version>.gem and gem-installs it
gem list asgard       # the checkout's version should be listed
```

Otherwise an older asgard gem already on the machine can be the one the
spawned processes run, and it will not understand `watch`.

## Walkthrough

From this directory:

```bash
asgard watcher start
```

```
started watcher for watcher_examples (pid 12345); log: ~/.local/state/asgard/watch/watcher-examples/watcher.log
```

Now make some changes and watch the log fill up:

```bash
echo '# a change' >> lib/greeter.rb         # lint runs, with the path in changes.modified
echo 'more' >> docs/index.md               # docs runs; BUILD_ENV=demo comes from env:
echo 'more' >> docs/drafts/ideas.md        # nothing: drafts/ is ignored
echo '{}' > data/new.json                  # reindex runs: a file was added
echo '{"edited": true}' > data/new.json    # nothing: events: is added and removed only
rm data/new.json                           # reindex runs again: a file was removed
asgard watcher log
```

```
2026-10-18 23:40:01 trigger lint task=lint lib/greeter.rb
2026-10-18 23:40:01 spawn lint task=lint pid=12351 lib/greeter.rb
lint: lib/greeter.rb (7 lines) triggered by lint
2026-10-18 23:40:02 exit lint task=lint pid=12351 status=0 seconds=0.41
2026-10-18 23:40:05 trigger docs task=docs docs/index.md
2026-10-18 23:40:05 spawn docs task=docs pid=12360 docs/index.md
docs: building for demo; changed: docs/index.md
2026-10-18 23:40:06 exit docs task=docs pid=12360 status=0 seconds=0.40
2026-10-18 23:40:09 trigger reindex task=reindex data/new.json
2026-10-18 23:40:09 spawn reindex task=reindex pid=12371 data/new.json
reindex: 1 added, 0 removed; 2 data file(s) now
2026-10-18 23:40:10 exit reindex task=reindex pid=12371 status=0 seconds=0.40
...
```

Each trigger line names the entry and the changed paths. Each spawn and
exit line carries the task's pid, so the lines of overlapping tasks can be
told apart; a task's own output sits between its spawn and its exit. Save
`lib/greeter.rb` twice in quick succession and the second trigger says
`(queued behind pid N)`: the same task never overlaps itself, while
different tasks run at the same time.

```bash
asgard watcher list
```

```
┌──────────┬────────────────┬──────────────────────────────────────┬──────────┬────────────────────────────────┐
│ NAME     │ TASK           │ WATCHES                              │ DAEMON   │ LAST RUN                       │
├──────────┼────────────────┼──────────────────────────────────────┼──────────┼────────────────────────────────┤
│ lint     │ asgard lint    │ lib/**/*.rb                          │ running  │ 0 (0.4s, 2026-10-18 23:40:02)  │
│ docs     │ asgard docs    │ docs                                 │ running  │ 0 (0.4s, 2026-10-18 23:40:06)  │
│ reindex  │ asgard reindex │ data/**/*.json [added, removed]      │ running  │ 0 (0.4s, 2026-10-18 23:40:14)  │
│ lint-bin │ asgard lint    │ bin/**/*                             │ running  │ never                          │
└──────────┴────────────────┴──────────────────────────────────────┴──────────┴────────────────────────────────┘
```

```bash
asgard watcher stop
```

A task that is still running finishes first; `stop` names it while it
waits.

## Running the tasks by hand

Every task works without the watcher too. `changes` is then empty, which
`lint` turns into "lint everything":

```bash
asgard lint
asgard docs
asgard reindex
```

## What the watcher restricts

A triggered task does not inherit the shell the watcher was started from.
It sees `PATH`, `HOME`, `USER`, `LANG` and a few other basics, the entry's
`env:`, a project `.envrc` through `direnv`, and the trigger variables
`ASGARD_WATCH`, `ASGARD_WATCH_ROOT`, `ASGARD_MODIFIED`, `ASGARD_ADDED` and
`ASGARD_REMOVED`. `asgard watcher preview` prints the exact command and
environment each entry would run.

Edit `.loki` while the watcher runs and it restarts itself with the new
declarations.
