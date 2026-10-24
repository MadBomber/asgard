# frozen_string_literal: true

require "thor"
require "tsort"

require_relative "base/registry"
require_relative "base/dependency_graph"
require_relative "base/task_dsl"
require_relative "base/dispatch"

module Asgard
  class Base < Thor
    include Asgard::Shell

    extend Registry
    extend DependencyGraph
    extend TaskDSL
    include Dispatch

    THOR_LIB   = File.dirname(Thor.method(:subcommand).source_location.first)
    ASGARD_LIB = File.expand_path("..", __dir__)

    # Names Thor's machinery relies on: its reserved words plus the readers
    # dispatch calls on every instance, which Thor itself does not guard.
    # A task or helper by one of these names breaks every command, with
    # nothing in the failure pointing at the cause.
    RESERVED_NAMES = (Thor::THOR_RESERVED_WORDS + %w[args parent_options]).map(&:to_sym).freeze

    class << self
      # A usage error (missing argument, unknown command or option) exits 1,
      # so CI and `asgard do` sequences see the failure. Thor's default is 0.
      def exit_on_failure? = true

      def header(text = nil)
        return @_header if text.nil?
        (@_header ||= []) << text
      end

      def footer(text = nil)
        return @_footer if text.nil?
        (@_footer ||= []).unshift(text)
      end

      # A method Thor generates (a `subcommand` dispatcher, a subcommand
      # class's string-eval'd `help`) reports a source_location inside Thor.
      # Credit it to the first caller frame outside Thor and asgard — the
      # .loki line that called `subcommand` — so Doctor lists it there.
      def definition_site(loc, callers)
        return loc unless thor_generated?(loc.first)

        site = callers.find { |frame| user_frame?(frame.path) }
        site ? [site.path, site.lineno] : loc
      end

      def thor_generated?(path)
        path.start_with?("(eval", THOR_LIB)
      end

      def user_frame?(path)
        !thor_generated?(path) && !path.start_with?(ASGARD_LIB)
      end

      def _check_reserved_name!(method_name)
        return unless RESERVED_NAMES.include?(method_name)

        file, line = instance_method(method_name).source_location
        remove_method(method_name) # leave Thor's own method in place, so the class still dispatches
        raise Asgard::Error,
              "'#{method_name}' at #{file}:#{line} is a name Thor reserves and cannot be a task or helper; rename it"
      end

      def method_added(method_name)
        _check_reserved_name!(method_name)
        name           = method_name.to_s
        private_method = name.start_with?("_")

        unless private_method
          loc = instance_method(method_name).source_location
          _method_log[method_name] << definition_site(loc, caller_locations) if loc
        end

        if @_pending_single_desc && !no_commands?
          pending_desc = @_pending_single_desc
          pending_opts = @_pending_single_desc_opts || {}
          @_pending_single_desc      = nil
          @_pending_single_desc_opts = nil
          desc(name, pending_desc, pending_opts)
        end

        return super unless @usage

        pending = Array(@_pending_deps).dup
        @_pending_deps = []

        return super if pending.empty?
        return super if private_method

        _deps[method_name.to_sym] = _normalize_pending_deps(pending)
        super
      end
    end

    def help(command = nil, subcommand = false) # rubocop:disable Style/OptionalBooleanParameter
      klass       = self.class
      top_level   = command.nil?
      header_text = klass.header
      footer_text = klass.footer

      say header_text.join("\n\n") if header_text && top_level
      say "\n"
      super
      say footer_text.join("\n\n") if footer_text && top_level
    end

    def tree
      klass       = self.class
      header_text = klass.header
      footer_text = klass.footer

      say header_text.join("\n\n") if header_text
      say "\n"
      super
      say "\n"
      say footer_text.join("\n\n") if footer_text
    end
  end
end
