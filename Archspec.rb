# frozen_string_literal: true

source "lib/**/*.rb"

component :shell,          in: "lib/asgard/shell.rb"
component :kernel_methods, in: "lib/asgard/kernel_methods.rb"
component :base,           in: %w[lib/asgard/base.rb lib/asgard/base/**/*.rb]
component :tasks,          in: "lib/asgard/tasks.rb"
component :doctor,         in: %w[lib/asgard/doctor.rb lib/asgard/doctor/**/*.rb]

# Scheduling. schedule_core is the platform-neutral half (the `schedule` DSL,
# declaration validation, the backend factory); schedule_commands is the
# `asgard schedule ...` CLI; each backend is one platform's adapter. The
# duplication Contract in contract/schedule_backend/ keeps the backends
# parallel on purpose; these rules keep that parallelism honest.
component :schedule_core,     in: %w[lib/asgard/schedule.rb lib/asgard/schedule/declaration.rb]
component :schedule_commands, in: %w[lib/asgard/schedule/commands.rb lib/asgard/schedule/table.rb]
BACKENDS = {
  launchd: "lib/asgard/schedule/launchd.rb",
  systemd: "lib/asgard/schedule/systemd.rb",
  cron:    "lib/asgard/schedule/cron.rb",
  windows: "lib/asgard/schedule/windows.rb"
}.freeze
BACKENDS.each { |name, file| component name, in: file }

# The instance API every backend implements, as documented in declaration.rb.
BACKEND_API = %i[
  scheduler files install uninstall start stop trigger
  installed_names installed_entries installed_columns installed_directory
  status log_path notes
].freeze

# What a backend may not reach out to when it runs a scheduler command. The
# injected runner (runner: Schedule.runner) is the only way out, so every
# backend is testable on every platform with a recording runner.
DIRECT_SHELL_OUTS = %i[system spawn popen capture2 capture2e capture3 exec].freeze

BACKENDS.each_key do |name|
  backend = public_send(name)
  others  = BACKENDS.keys - [name]

  backend.must_implement(*BACKEND_API,
                         because: "Schedule::Commands never branches on which backend it has (Contract B1)")
  backend.cannot_use(*others, :schedule_commands,
                     because: "backends stay independent of each other and of the CLI (Contract B3)")
  backend.can_only_be_used_by(:schedule_core, :schedule_commands,
                              because: "a backend is reached only through Schedule.backend_class and the schedule CLI")
  backend.cannot_reference_constants("Open3",
                                     because: "backends shell out only through the injected runner (Contract B2)")
  backend.cannot_call(*DIRECT_SHELL_OUTS,
                      because: "backends shell out only through the injected runner (Contract B2)")
end

# The platform-neutral half knows the backends (it picks one) but never the CLI.
schedule_core.cannot_use :schedule_commands, :tasks, :doctor

# The DSL engine must not depend upward on the classes built on top of it —
# Tasks, Doctor and the scheduler are consumers of Base, never the other way around.
base.cannot_use :tasks, :doctor, :schedule_core, :schedule_commands, *BACKENDS.keys

# Built-in/user tasks stay independent of the --doctor introspection feature.
tasks.cannot_use :doctor

# Shell (sh/shebang helpers, mixed into Base) and the Kernel additions (env,
# loki_up, import, ...) are leaf-level utilities — they must not depend on
# anything built on top of them.
shell.cannot_use :base, :tasks, :doctor, :schedule_core, :schedule_commands, *BACKENDS.keys
kernel_methods.cannot_use :base, :tasks, :doctor, :shell, :schedule_core, :schedule_commands, *BACKENDS.keys

# Two cycles are deliberate and left out of the check:
#   tasks <-> schedule_commands: Tasks mounts the `schedule` subcommand, and
#     the subcommand validates declared task names against Tasks.all_commands.
#   schedule_core <-> backends: Schedule.backend_class (declaration.rb) picks a
#     backend, and backends call the neutral helpers in the same file. Moving
#     the factory to its own file would let the backends join this list.
no_cycles among: %i[base tasks doctor shell kernel_methods schedule_core]
