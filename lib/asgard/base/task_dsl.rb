# frozen_string_literal: true

module Asgard
  class Base < Thor
    # Task-definition macros available inside .loki files: single-argument
    # `desc`, `--no-x`/`--skip-x` suppression, `.env` loading, the `helper`
    # DSL, and `default_task` override warnings.
    module TaskDSL
      # Allow single-argument desc: desc "Run the tests"
      # The usage string defaults to the method name when the description is the only arg.
      def desc(usage_or_desc, description = nil, options = {})
        is_hash = description.is_a?(Hash)
        if description.nil? || is_hash
          options = description if is_hash
          @_pending_single_desc      = usage_or_desc
          @_pending_single_desc_opts = options
        else
          @_pending_single_desc      = nil
          @_pending_single_desc_opts = nil
          super
        end
      end

      # Suppress [--no-name] / [--skip-name] from help for boolean class options
      # where negation is meaningless. Call after class_option declarations.
      def no_negate(*names)
        names.each do |name|
          opt = class_options[name]
          next unless opt
          opt.define_singleton_method(:usage) do |padding = 0|
            aliases_for_usage.ljust(padding) + "[#{switch_name}]"
          end
        end
      end

      def dotenv(path = ".env")
        require "dotenv"
        Dotenv.load(path) if File.exist?(path)
      end

      def helper(name, &)
        define_singleton_method(name, &)
        no_commands { private define_method(name) { |*args, **kwargs, &blk| self.class.send(name, *args, **kwargs, &blk) } }
      end

      def default_task(meth = nil)
        active = meth && meth != :none
        here   = caller_locations(1, 1).first if active

        if active && @_default_task_location
          # rubocop:disable-next Style/StderrPuts -- warn bypasses $stderr in Ruby 4.0, breaking capture_io in tests
          $stderr.puts "asgard: default_task :#{meth} at #{here.path}:#{here.lineno} " \
                       "overrides default_task :#{@_default_task_name} set at " \
                       "#{@_default_task_location.path}:#{@_default_task_location.lineno}"
        end
        if active
          @_default_task_location = here
          @_default_task_name     = meth
        end
        super
      end
    end
  end
end
