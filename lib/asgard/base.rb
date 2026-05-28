# frozen_string_literal: true

require "thor"
require "simple_flow"

module Asgard
  class Base < Thor
    include Asgard::Shell

    class << self
      def subclasses
        @subclasses ||= []
      end

      def inherited(subclass)
        super
        Asgard::Base.subclasses << subclass
        subclass.instance_variable_set(:@_deps, {})
        subclass.instance_variable_set(:@_vars, {})
        subclass.instance_variable_set(:@_pending_deps, [])
      end

      def _deps
        @_deps ||= {}
      end

      def _vars
        @_vars ||= {}
      end

      # Declare that the next defined method depends on these recipes.
      #
      #   depends_on :build
      #   depends_on :lint, :typecheck
      def depends_on(*recipes)
        @_pending_deps = Array(recipes).flatten.map(&:to_sym)
      end

      # Declare a variable available to all recipes as an instance method.
      # Value may be a literal or a callable for lazy evaluation.
      #
      #   var :app,     "myapp"
      #   var :version, -> { `git describe --tags`.strip }
      def var(name, value = nil, &block)
        value = block if block_given?
        _vars[name.to_sym] = value
        # no_commands prevents Thor from treating these accessors as CLI commands.
        no_commands do
          define_method(name) do
            v = self.class._vars[name.to_sym]
            v.respond_to?(:call) ? v.call : v
          end
        end
      end

      # Flat-import another task module. The module's +included+ hook registers
      # tasks into this class via +base.desc+ and +base.define_method+.
      def import(mod)
        include mod
      end

      # Load a .env file (default: ".env" in CWD).
      def dotenv(path = ".env")
        require "dotenv"
        Dotenv.load(path) if File.exist?(path)
      end

      # Validate the dep graph for cycles. Raises Asgard::CircularDependencyError.
      def validate_deps!
        return if _deps.empty?

        all_tasks  = all_commands.keys.map(&:to_sym)
        full_graph = all_tasks.each_with_object({}) do |task, hash|
          hash[task] = _deps.fetch(task, [])
        end

        SimpleFlow::DependencyGraph.new(full_graph).order
      rescue TSort::Cyclic => e
        raise Asgard::CircularDependencyError, e.message
      end

      def method_added(method_name)
        pending = Array(@_pending_deps).dup
        @_pending_deps = []

        return super if pending.empty?
        return super if method_name.to_s.start_with?("_")

        _deps[method_name.to_sym] = pending
        super
      end
    end

    no_commands do
      # Run deps before every command dispatch. Thor's invoke is idempotent —
      # each dep runs at most once per invocation, regardless of how many recipes
      # declare it.
      def invoke_command(command, *args)
        target = command.name.to_sym
        (self.class._deps[target] || []).each { |dep| invoke dep }
        super
      end
    end
  end
end
