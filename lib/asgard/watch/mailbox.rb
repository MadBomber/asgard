# frozen_string_literal: true

require "ractor_queue"

module Asgard
  module Watch
    # A bounded RactorQueue whose consumer sleeps instead of spinning.
    # RactorQueue#pop polls every 100µs, which an idle daemon with a few
    # workers pays for as a constant few percent of a core. Here the
    # consumer pops with try_pop and, when the queue is empty, blocks in
    # Ractor.receive; every push sends the consumer's Ractor (+owner+) a
    # wake-up. A wake-up sent after the push can never be missed, and an
    # extra one only costs one more empty try_pop. Ractor.receive is
    # Ruby 3.x and 4.x alike.
    Mailbox = Data.define(:queue, :owner) do
      def self.ring(ractor)
        ractor << :ring if ractor.is_a?(Ractor)
      rescue Ractor::ClosedError
        nil # the consumer has ended; nothing is waiting
      end

      # Blocking push (RactorQueue#push spins only while the queue is full).
      def push(item)
        queue.push(item)
        Mailbox.ring(owner)
        self
      end

      # false when the queue is full. Named after RactorQueue#try_push.
      def try_push(item) # rubocop:disable Naming/PredicateMethod
        return false unless queue.try_push(item)

        Mailbox.ring(owner)
        true
      end

      # Must be called in +owner+, the Ractor the wake-ups go to.
      def pop
        loop do
          item = queue.try_pop
          return item unless item.equal?(RactorQueue::EMPTY)

          Ractor.receive
        end
      end

      def empty? = queue.empty?
    end
  end
end
