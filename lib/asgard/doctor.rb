# frozen_string_literal: true

require "pathname"

require_relative "doctor/task_sections"
require_relative "doctor/report"

module Asgard
  # Diagnoses .loki resolution, import chains, and task definitions for a
  # directory — invoked via `asgard --doctor`. Deliberately bypasses the
  # normal Tasks boot sequence (see Asgard.run!) so it can still report
  # findings when that sequence would otherwise abort the whole process
  # (a broken file, a circular dependency, a silently overridden task).
  class Doctor
    include TaskSections
    include Report

    Finding = Struct.new(:level, :message, keyword_init: true)

    def initialize(dir = Dir.pwd)
      @dir          = File.expand_path(dir)
      @findings     = []
      @imports      = []
      @loaded_files = []
    end

    def run
      report_markers
      load_chain
      report_imports
      build_task_sections
      report_dependencies
      print_report
    end

    # Every ".loki" marker from +dir+ up to the filesystem root, nearest
    # first — mirrors loki_up's walk, but collects every match instead of
    # stopping at the first (so shadowed ancestor markers can be reported).
    def self.ancestor_markers(dir)
      markers = []
      current = Pathname.new(dir)
      loop do
        candidate = current + ".loki"
        markers << candidate.to_s if candidate.exist?
        parent = current.parent
        break if parent == current

        current = parent
      end
      markers
    end

    # method_name => [[file, line], ...] entries defined more than once —
    # same file or different, a later `def` always silently overrides an
    # earlier one with the same name.
    def self.duplicate_methods(method_log)
      method_log.each_with_object({}) do |(name, locations), acc|
        acc[name] = locations if locations.size > 1
      end
    end

    private

    def report_markers
      markers = self.class.ancestor_markers(@dir)
      if markers.empty?
        @findings << Finding.new(level: :error, message: "no .loki file found in #{@dir} or any ancestor")
        return
      end

      @marker = markers.first
      @findings << Finding.new(level: :info, message: "using .loki marker: #{@marker}")
      markers[1..].each do |shadowed|
        @findings << Finding.new(level: :warn, message: "shadowed marker (never reached): #{shadowed}")
      end
    end

    def load_chain
      return unless @marker

      Kernel.prepend(ImportTracer)
      ImportTracer.doctor = self
      @loaded_files << @marker

      before = Asgard::Base.subclasses.dup
      load @marker
      @new_subclasses = (Asgard::Base.subclasses - before + [Tasks]).uniq
    rescue StandardError, ScriptError => e
      @findings << Finding.new(level: :error, message: "load failed: #{e.class}: #{e.message}")
    ensure
      ImportTracer.doctor = nil
    end

    def report_imports
      @imports.each { |message| @findings << Finding.new(level: :info, message: message) }
    end

    def report_dependencies
      return unless @new_subclasses

      @new_subclasses.each do |klass|
        klass.validate_deps!
      rescue Asgard::Error => e
        @findings << Finding.new(level: :error, message: "#{klass} dependency graph: #{e.message}")
      end
    end

    def record_import(message, added = [])
      @imports << message
      @loaded_files.concat(added)
    end

    # Prepended onto Kernel for the process lifetime of `asgard --doctor`
    # (Asgard.run! exits right after Doctor#run, so it's never unprepended)
    # to observe every import/import_up call, whether typed at the top
    # level of a .loki file or reached indirectly through another import.
    module ImportTracer
      class << self
        attr_accessor :doctor
      end

      def import(path)
        loc    = caller_locations(1, 1).first
        before = $LOADED_FEATURES.dup
        result = super(path, from: loc)
        added  = $LOADED_FEATURES - before
        ImportTracer.doctor&.send(:record_import, ImportTracer.trace_message("import", path, added), added) unless
          loc&.absolute_path&.end_with?("kernel_methods.rb")
        result
      end

      def import_up(name = ".loki")
        before = $LOADED_FEATURES.dup
        result = super
        added  = $LOADED_FEATURES - before
        ImportTracer.doctor&.send(:record_import, ImportTracer.trace_message("import_up", name, added), added)
        result
      end

      def self.trace_message(verb, arg, added)
        inspected = arg.inspect
        return "#{verb} #{inspected} -- nothing new (not found or already loaded)" if added.empty?

        "#{verb} #{inspected} -> #{added.join(', ')}"
      end

      private :import, :import_up
    end
  end
end
