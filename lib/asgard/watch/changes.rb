# frozen_string_literal: true

module Asgard
  # The files a watcher trigger saw change, as three lists of paths relative
  # to the project root. The watcher hands them to the task through three
  # environment variables (newline-separated, since paths may hold spaces
  # or colons); the `changes` Kernel method reads them back. Every list is
  # empty when the task is run by hand, so one task body serves both.
  class Changes < Data.define(:modified, :added, :removed)
    VARIABLES = { modified: "ASGARD_MODIFIED", added: "ASGARD_ADDED", removed: "ASGARD_REMOVED" }.freeze

    class << self
      # The changes behind this process, read once from ENV. Tests and a
      # watcher-run task that re-execs call forget to read them again.
      def current = @current ||= from_env

      def forget = @current = nil

      # Parses the trigger variables; a missing one is an empty list.
      def from_env(env = ENV) = new(**VARIABLES.to_h { |member, variable| [member, env[variable].to_s.split("\n")] })
    end

    def initialize(modified: [], added: [], removed: [])
      super(modified: modified.map(&:to_s).freeze, added: added.map(&:to_s).freeze, removed: removed.map(&:to_s).freeze)
    end

    # Every changed path once, in modified, added, removed order.
    def all = (modified + added + removed).uniq

    def empty? = modified.empty? && added.empty? && removed.empty?

    # The trigger variables that reproduce this object through from_env.
    def to_env = VARIABLES.to_h { |member, variable| [variable, public_send(member).join("\n")] }
  end

  module Watch
    # Which Changes member each events: kind fills. Listen reports the first
    # kind as "modified".
    EVENT_MEMBERS = { changed: :modified, added: :added, removed: :removed }.freeze

    module_function

    # A listener batch ({ modified:, added:, removed: }) narrowed to the
    # kinds in events (a Set from normalize_events), as a Changes; nil
    # when nothing is left, so the dispatcher skips the trigger.
    def filter_events(batch, events)
      kept    = EVENT_MEMBERS.to_h { |event, member| [member, events.include?(event) ? Array(batch[member]) : []] }
      changes = Changes.new(**kept)
      changes.empty? ? nil : changes
    end
  end
end
