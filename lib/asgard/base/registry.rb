# frozen_string_literal: true

module Asgard
  class Base < Thor
    # Tracks every Asgard::Base subclass ever defined, and every method
    # name's full source_location history — the data Doctor (`asgard
    # --doctor`) uses to detect a silently-overridden `def`, same file or
    # across files.
    module Registry
      # Every subclass of Asgard::Base, at any depth, in definition order.
      # Not `subclasses`: that is Ruby's own Class#subclasses (direct
      # subclasses only), which a .loki may well call.
      def _asgard_subclasses
        @_asgard_subclasses ||= []
      end

      def inherited(subclass)
        super
        Asgard::Base._asgard_subclasses << subclass
        subclass.instance_variable_set(:@_deps,              {})
        subclass.instance_variable_set(:@_method_log,        Hash.new { |h, k| h[k] = [] })
        subclass.instance_variable_set(:@_pending_deps,      [])
        subclass.instance_variable_set(:@_pending_single_desc,      nil)
        subclass.instance_variable_set(:@_pending_single_desc_opts, nil)
        subclass.instance_variable_set(:@_running,    Set.new)
        subclass.instance_variable_set(:@_done,       Set.new)
        subclass.instance_variable_set(:@_cond,       Hash.new { |h, k| h[k] = ConditionVariable.new })
        subclass.instance_variable_set(:@_ran_mutex,  Mutex.new)
        subclass.instance_variable_set(:@_failed,     {})
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
