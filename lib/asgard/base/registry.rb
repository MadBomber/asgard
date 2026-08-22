# frozen_string_literal: true

module Asgard
  class Base < Thor
    # Tracks every Asgard::Base subclass ever defined, and every method
    # name's full source_location history — the data Doctor (`asgard
    # --doctor`) uses to detect a silently-overridden `def`, same file or
    # across files.
    module Registry
      def subclasses
        @subclasses ||= []
      end

      def inherited(subclass)
        super
        Asgard::Base.subclasses << subclass
        subclass.instance_variable_set(:@_deps,              {})
        subclass.instance_variable_set(:@_method_log,        Hash.new { |h, k| h[k] = [] })
        subclass.instance_variable_set(:@_pending_deps,      [])
        subclass.instance_variable_set(:@_pending_single_desc,      nil)
        subclass.instance_variable_set(:@_pending_single_desc_opts, nil)
        subclass.instance_variable_set(:@_running,    Set.new)
        subclass.instance_variable_set(:@_done,       Set.new)
        subclass.instance_variable_set(:@_cond,       Hash.new { |h, k| h[k] = ConditionVariable.new })
        subclass.instance_variable_set(:@_ran_mutex,  Mutex.new)
      end

      # Every source_location a method name has ever been defined at, in
      # definition order — so a later `def` silently overriding an earlier
      # one (same name, different file) is still visible after the fact.
      # Doctor is the consumer; asgard itself doesn't otherwise care once
      # the last definition wins.
      def _method_log
        @_method_log ||= Hash.new { |h, k| h[k] = [] }
      end
    end
  end
end
