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

    # The helpers lib/asgard/kernel_methods.rb adds to Kernel.
    KERNEL_HELPERS = %i[debug? verbose? env changes loki_up import import_up].freeze

    # Asgard's own helpers a task body calls (sh, env, dep_result, ...)
    # and the methods dispatch runs every task through. A task or helper
    # by one of these names would silently replace it.
    ASGARD_HELPERS = [Shell, Dispatch].flat_map { |mod| mod.instance_methods(false) + mod.private_instance_methods(false) }
                                      .concat(KERNEL_HELPERS).uniq.freeze

    class << self
      # A usage error (missing argument, unknown command or option) exits 1,
      # so CI and `asgard do` sequences see the failure. Thor's default is 0.
      def exit_on_failure? = true

      # A subcommand group's help lists only the group's own commands. The
      # tasks it inherits from Tasks still run, but Thor would list them
      # too, under the class's default namespace (doc_commands for
      # DocCommands), burying the group's own.
      def printable_commands(all = true, subcommand = false) # rubocop:disable Style/OptionalBooleanParameter
        super(all && !subcommand, subcommand)
      end

      # `subcommand "doc", DocCommands` names the group doc, so `tree` shows
      # it as doc rather than Thor's doc_commands. A group that set its own
      # namespace keeps it.
      def subcommand(name, klass)
        klass.namespace(name) if klass.namespace == Thor::Util.namespace_from_thor_class(klass)
        super
      end

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

      HIDDEN_DESC = "(hidden task: defined without a desc)"

      # A public method a .loki defines without a desc is a hidden task:
      # it runs from the command line and as a dependency, and help leaves
      # it out. Not one: a method that already has a desc pending, anything
      # inside no_commands (helpers), non-public methods, the gem's own
      # _-prefixed names, and a name Thor already has a command for (help).
      # Nor a method every object already has (to_s, inspect,
      # respond_to_missing?): see object_method?.
      def implicit_hidden_task?(method_name)
        name = method_name.to_s
        !@usage && !no_commands? && !name.start_with?("_") && !object_method?(method_name) &&
          public_method_defined?(method_name) && !all_commands.key?(name)
      end

      # A method Thor (and so Object) already defines: a public one
      # (to_s, inspect, display), or a private one that is not a Kernel
      # module function (method_missing, respond_to_missing?). Kernel's
      # module functions (test, format, system) stay free to be task names.
      def object_method?(method_name)
        Thor.public_method_defined?(method_name) ||
          (Thor.private_method_defined?(method_name) && !Kernel.respond_to?(method_name))
      end

      # The task `asgard help NAME` describes: a built-in group's mapped
      # name ("jobs") is its registered subcommand ("_jobs"); anything else
      # is NAME unchanged.
      def help_target(command)
        mapped = map[command.to_s]&.to_s
        subcommands.include?(mapped) ? mapped : command
      end

      def _check_reserved_name!(method_name)
        thor = RESERVED_NAMES.include?(method_name)
        return unless thor || ASGARD_HELPERS.include?(method_name)

        file, line = instance_method(method_name).source_location
        remove_method(method_name) # leave the original in place, so the class still dispatches
        what = thor ? "a name Thor reserves" : "an asgard helper"
        raise Asgard::Error, "'#{method_name}' at #{file}:#{line} is #{what} and cannot be a task or helper; rename it"
      end

      # A redefined to_s or inspect with no desc of its own: not a task, and
      # not worth Thor's "without usage or description" warning either.
      def plain_object_method?(method_name) = !@usage && !@_pending_single_desc && object_method?(method_name)

      # Turns a pending single-argument `desc "text"` into Thor's desc for
      # the method just defined.
      def _apply_pending_desc(name)
        return unless @_pending_single_desc && !no_commands?

        pending_desc = @_pending_single_desc
        pending_opts = @_pending_single_desc_opts || {}
        @_pending_single_desc      = nil
        @_pending_single_desc_opts = nil
        desc(name, pending_desc, pending_opts)
      end

      def method_added(method_name)
        _check_reserved_name!(method_name)
        return no_commands { super } if plain_object_method?(method_name)

        name           = method_name.to_s
        private_method = name.start_with?("_")

        unless private_method
          loc = instance_method(method_name).source_location
          _method_log[method_name] << definition_site(loc, caller_locations) if loc
        end

        _apply_pending_desc(name)
        desc(name, HIDDEN_DESC, hide: true) if implicit_hidden_task?(method_name)

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
      super(klass.help_target(command), subcommand)
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
