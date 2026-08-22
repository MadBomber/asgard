# frozen_string_literal: true

module Asgard
  class Doctor
    # Builds the "Tasks by file" data: every command grouped by the file
    # it's defined in, with each definition annotated when a task name has
    # more than one recorded location (the each/each_gem class of bug) —
    # earlier ones OVERRIDDEN (dead), the last one the active redefinition.
    module TaskSections
      private

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
        size = locations.size
        if idx == size - 1
          return nil if size == 1

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
          file_map.values.flatten(1).count { |t| t[2]&.start_with?("OVERRIDDEN") }
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
    end
  end
end
