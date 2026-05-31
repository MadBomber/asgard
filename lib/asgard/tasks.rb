# frozen_string_literal: true

# Tasks is the single conventional entry point for all .loki files.
# It is pre-defined by the gem so .loki files never need to declare a class.
# Auxiliary *.loki files define modules which are imported into Tasks.
class Tasks < Asgard::Base
  header "\nasgard v#{Asgard::VERSION} The Mighty Thor and Loki working for you"

  footer <<~FOOT
    \nDocumentation ... https://madbomber.github.io/asgard
    Github Repo ..... https://github.com/MadBomber/asgard\n
  FOOT

  class_option :debug,
               type:    :boolean,
               default: false,
               desc:    "Enable debug mode ($DEBUG = true)"

  class_option :verbose,
               type:    :boolean,
               default: false,
               desc:    "Enable verbose output ($VERBOSE = true)"

  class_option :version,
               type:    :boolean,
               default: false,
               desc:    "Show asgard version and exit"
  no_negate :version
end
