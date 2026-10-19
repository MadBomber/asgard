# frozen_string_literal: true

require "ractor_queue"

module Asgard
  module Watch
    # Routes listener batches to worker queues. Built once at startup from
    # the declarations: a dispatch table from listener id (the entry name)
    # to its spec, and one worker per distinct task, so two declarations
    # for the same task share a worker and never overlap. Nothing here is
    # mutated after construction, and the loop never blocks on a worker.
    class Dispatcher
      # Triggers a busy task can have waiting. RactorQueue rounds this up.
      QUEUE_CAPACITY = 256

      attr_reader :dispatch, :workers

      # start: makes a worker from (queue, reports); the default starts a
      # real Ractor. clock: supplies the trigger timestamp.
      def initialize(declarations, context, reports:, start: Worker.method(:start), clock: Time)
        specs     = declarations.values
        @context  = context
        @reports  = reports
        @clock    = clock
        @dispatch = specs.to_h { |spec| [spec[:name], spec] }.freeze
        @workers  = specs.map { |spec| spec[:task] }.uniq.to_h do |task|
          queue = RactorQueue.new(capacity: QUEUE_CAPACITY)
          [task, { queue:, ractor: start.call(queue, reports) }.freeze]
        end.freeze
      end

      # Pops [listener id, batch] pairs from inbox until it pops nil.
      def run(inbox)
        while (id, batch = inbox.pop)
          route(id, batch)
        end
      end

      def start(inbox) = Thread.new { run(inbox) }

      # One batch: drop the kinds the entry does not watch, build the frozen
      # description, report the trigger, hand it to the task's worker. The
      # description, or nil when nothing was left to run.
      def route(id, batch)
        spec    = @dispatch.fetch(id)
        changes = Watch.filter_events(batch, spec[:events]) or return nil
        task    = spec[:task]
        description = Spawn.description(spec, changes, @context)
        @reports.push(Ractor.make_shareable({ kind: :trigger, entry: spec[:name], task:, at: @clock.now.to_f, changes: changes.to_h }))
        @workers.fetch(task)[:queue].push(description)
        description
      end
    end
  end
end
