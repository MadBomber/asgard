# frozen_string_literal: true

source "lib/**/*.rb"

component :shell,          in: "lib/asgard/shell.rb"
component :kernel_methods, in: "lib/asgard/kernel_methods.rb"
component :base,           in: %w[lib/asgard/base.rb lib/asgard/base/**/*.rb]
component :tasks,          in: "lib/asgard/tasks.rb"
component :doctor,         in: %w[lib/asgard/doctor.rb lib/asgard/doctor/**/*.rb]

# The DSL engine must not depend upward on the classes built on top of it —
# Tasks and Doctor are consumers of Base, never the other way around.
base.cannot_use :tasks, :doctor

# Built-in/user tasks stay independent of the --doctor introspection feature.
tasks.cannot_use :doctor

# Shell (sh/shebang helpers, mixed into Base) and the Kernel additions (env,
# loki_up, import, ...) are leaf-level utilities — they must not depend on
# anything built on top of them.
shell.cannot_use :base, :tasks, :doctor
kernel_methods.cannot_use :base, :tasks, :doctor, :shell

no_cycles among: %i[base tasks doctor shell kernel_methods]
