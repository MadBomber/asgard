# frozen_string_literal: true

# Tasks is the single conventional entry point for all .loki files.
# It is pre-defined by the gem so .loki files never need to declare a class.
# Auxiliary *.loki files define modules which are imported into Tasks.
class Tasks < Asgard::Base
  desc "--debug", "Set debug mode"
  map "--debug" => :_debug
  def _debug = $DEBUG = true

  desc "--version", "Show asgard version"
  map "--version" => :_version
  def _version
    puts Asgard::VERSION
    exit
  end

  desc "--verbose", "Set verbose output"
  map "--verbose" => :_verbose
  def _verbose = $VERBOSE = true
end
