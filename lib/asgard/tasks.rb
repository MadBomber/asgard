# frozen_string_literal: true

# Tasks is the single conventional entry point for all .loki files.
# It is pre-defined by the gem so .loki files never need to declare a class.
# Auxiliary *.loki files define modules which are imported into Tasks.
class Tasks < Asgard::Base; end
