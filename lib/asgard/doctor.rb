# frozen_string_literal: true

require "pathname"

module Asgard
  # Diagnoses .loki resolution, import chains, and task definitions for a
  # directory — invoked via `asgard --doctor`. Deliberately bypasses the
  # normal Tasks boot sequence (see Asgard.run!) so it can still report
  # findings when that sequence would otherwise abort the whole process
  # (a broken file, a circular dependency, a silently overridden task).
  class Doctor
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

    # Groups every task by the file it's defined in, in load order, so the
    # report reads like a table of contents an editor can jump into. A task
    # name with more than one recorded location (the each/each_gem class of
    # bug) gets each of its definitions annotated: earlier ones are marked
    # OVERRIDDEN (dead — never callable) and the last one is marked as the
    # active redefinition, so the whole silently-broken chain is visible
    # inline instead of as a separate summary finding.
    def build_task_sections
      @task_sections = []
      return unless @new_subclasses

      @task_sections = @new_subclasses.map { |klass| [klass, class_task_file_map(klass)] }
    end

    def class_task_file_map(klass)
      file_map = Hash.new { |h, k| h[k] = [] }
      @loaded_files.each { |f| file_map[f] }

      commands = klass.all_commands.keys
      klass._method_log.each do |name, locations|
        next unless commands.include?(name.to_s)

        locations.each_with_index do |(file, line), idx|
          file_map[file] << [name, line, task_status(locations, idx)]
        end
      end
      file_map.each_value { |tasks| tasks.sort_by! { |t| t[1] } }
    end

    def task_status(locations, idx)
      if idx == locations.size - 1
        return nil if locations.size == 1

        prev_file, prev_line = locations[idx - 1]
        "active — redefines #{relative_path(prev_file)}:#{prev_line}"
      else
        next_file, next_line = locations[idx + 1]
        "OVERRIDDEN by #{relative_path(next_file)}:#{next_line} — never callable"
      end
    end

    def override_count
      return 0 unless @task_sections

      @task_sections.sum do |_klass, file_map|
        file_map.values.sum { |tasks| tasks.count { |t| t[2]&.start_with?("OVERRIDDEN") } }
      end
    end

    # +file+ is normally absolute (every path Doctor loads is expanded
    # first), but a method's recorded source_location can be relative if it
    # was defined by code invoked with a relative path (e.g. `ruby some.rb`
    # rather than an absolute one) — display it verbatim rather than crash.
    def relative_path(file)
      path = Pathname.new(file)
      return file unless path.absolute?

      path.relative_path_from(Pathname.new(@dir)).to_s
    end

    def report_dependencies
      return unless @new_subclasses

      @new_subclasses.each do |klass|
        klass.validate_deps!
      rescue Asgard::Error => e
        @findings << Finding.new(level: :error, message: "#{klass} dependency graph: #{e.message}")
      end
    end

    def print_report
      puts "\nasgard doctor -- #{@dir}"
      puts "=" * 60
      @findings.each { |finding| puts format_finding(finding) }
      print_task_sections
      puts "=" * 60
      puts summary_line
    end

    def print_task_sections
      return if @task_sections.nil? || @task_sections.empty?

      multi_class = @task_sections.size > 1
      @task_sections.each do |klass, file_map|
        header = multi_class ? "Tasks by file (#{klass}):" : "Tasks by file:"
        puts "\n#{header}"
        file_map.each { |file, tasks| print_file_tasks(file, tasks) }
      end
    end

    def print_file_tasks(file, tasks)
      puts "\n  #{relative_path(file)}"
      return puts "    (no tasks defined — imports only)" if tasks.empty?

      width = tasks.map { |name, _, _| name.to_s.length }.max
      tasks.each { |task| puts format_task_line(file, task, width) }
    end

    def format_task_line(file, task, width)
      name, line, status = task
      text = "    #{name.to_s.ljust(width)}  #{relative_path(file)}:#{line}"
      text += "   #{status}" if status
      return colorize(31, text) if status&.start_with?("OVERRIDDEN")
      return colorize(33, text) if status

      text
    end

    def format_finding(finding)
      case finding.level
      when :error then colorize(31, "  [FAIL] #{finding.message}")
      when :warn  then colorize(33, "  [WARN] #{finding.message}")
      else colorize(36, "  [INFO] #{finding.message}")
      end
    end

    def summary_line
      errors = @findings.count { |f| f.level == :error } + override_count
      warns  = @findings.count { |f| f.level == :warn }
      return colorize(32, "No problems found.") if errors.zero? && warns.zero?
      return colorize(33, "No problems found (#{warns} warning(s)).") if errors.zero?

      colorize(31, "#{errors} problem(s), #{warns} warning(s).")
    end

    def colorize(code, text)
      "\e[#{code}m#{text}\e[0m"
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
        return "#{verb} #{arg.inspect} -- nothing new (not found or already loaded)" if added.empty?

        "#{verb} #{arg.inspect} -> #{added.join(', ')}"
      end

      private :import, :import_up
    end
  end
end
