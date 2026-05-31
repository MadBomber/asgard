# frozen_string_literal: true

# Tasks is the single conventional entry point for all .loki files.
# It is pre-defined by the gem so .loki files never need to declare a class.
# Auxiliary *.loki files define modules which are imported into Tasks.
class Tasks < Asgard::Base
  class_option :debug,
               type:    :boolean,
               default: false,
               desc:    "Enable debug mode ($DEBUG = true)"

  class_option :verbose,
               type:    :boolean,
               default: false,
               desc:    "Enable verbose output ($VERBOSE = true)"

  desc "--version", "Show asgard version"
  map "--version" => :_version
  def _version
    puts Asgard::VERSION
    exit
  end
end
