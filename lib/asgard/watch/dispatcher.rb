# frozen_string_literal: true

require "json"
require "fileutils"
require "ractor_queue"

module Asgard
  module Watch
    # Routes listener batches to worker queues. Built once at startup from
    # the declarations: a dispatch table from listener id (the entry name)
    # to its spec, and one worker per distinct task, so two declarations
    # for the same task share a worker and never overlap. Nothing here is
    # mutated after construction but a spill counter, and the loop never
    # blocks on a worker: a trigger for a full queue is dropped and reported.
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
        @spills   = 0
        @dispatch = specs.to_h { |spec| [spec[:name], spec] }.freeze
        @workers  = specs.map { |spec| spec[:task] }.uniq.to_h do |task|
          queue  = RactorQueue.new(capacity: QUEUE_CAPACITY)
          ractor = start.call(queue, reports)
          [task, { queue:, ractor:, mailbox: Mailbox.new(queue, ractor) }.freeze]
        end.freeze
      end

      # Every item waiting on +queue+, oldest first, leaving it empty.
      def self.take_waiting(queue)
        items = []
        until (item = queue.try_pop).equal?(RactorQueue::EMPTY)
          items << item
        end
        items
      end

      # Pops [listener id, batch] pairs from inbox until it pops nil.
      def run(inbox)
        while (id, batch = inbox.pop)
          route(id, batch)
        end
      end

      def start(inbox) = Thread.new { run(inbox) }

      # One batch: drop the kinds the entry does not watch, report the
      # trigger, and queue it for the task's worker, merged with any trigger
      # of the same entry still waiting there, so a busy task runs once more
      # with every change rather than once per save. The queued description,
      # or nil when nothing was left to run or the queue was full.
      def route(id, batch)
        spec    = @dispatch.fetch(id)
        changes = Watch.filter_events(batch, spec[:events]) or return nil
        task    = spec[:task]
        report  = { entry: spec[:name], task:, at: @clock.now.to_f, changes: changes.to_h }
        @reports.push(Ractor.make_shareable({ kind: :trigger, **report }))
        enqueue(spec, changes, @workers.fetch(task)[:mailbox]) || drop(report)
      end

      private

      # Takes back what is still waiting in +mailbox+, folds this entry's
      # waiting triggers into the new one and queues the rest back first, in
      # their order. A worker that took one meanwhile simply runs it.
      def enqueue(spec, changes, mailbox)
        same, others = Dispatcher.take_waiting(mailbox.queue).partition { |item| item.is_a?(Hash) && item[:entry] == spec[:name] }
        same.each { |item| Worker.remove_changes_file(item[:changes_file]) }
        merged = Watch.merge_changes([*same.map { |item| Changes.new(**item[:changes]) }, changes])
        description = Spawn.description(spec, merged, @context, changes_file: next_changes_file(spec))
        others.each { |item| mailbox.try_push(item) }
        write_changes_file(description) # before the push: the worker may start it at once
        return description if mailbox.try_push(description)

        Worker.remove_changes_file(description[:changes_file])
        nil
      end

      def drop(report)
        @reports.push(Ractor.make_shareable({ kind: :dropped, **report }))
        nil
      end

      # Where this trigger's change lists go if they are too big for the
      # environment; the file is only written when Spawn spilled to it.
      def next_changes_file(spec)
        @spills += 1
        Spawn.changes_file(@context, spec[:name], @spills)
      end

      def write_changes_file(description)
        path = description[:changes_file] or return
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate(description[:changes]))
      end
    end
  end
end
