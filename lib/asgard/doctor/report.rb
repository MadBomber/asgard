# frozen_string_literal: true

module Asgard
  class Doctor
    # Renders the full doctor report to stdout: findings, the Tasks-by-file
    # listing, and the closing summary line.
    module Report
      private

      def print_report
        divider = "=" * 60
        puts "\nasgard doctor -- #{@dir}"
        puts divider
        @findings.each { |finding| puts format_finding(finding) }
        print_task_sections
        puts divider
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
        message = finding.message
        case finding.level
        when :error then colorize(31, "  [FAIL] #{message}")
        when :warn  then colorize(33, "  [WARN] #{message}")
        else colorize(36, "  [INFO] #{message}")
        end
      end

      def summary_line
        by_level = @findings.group_by(&:level)
        errors   = (by_level[:error]&.size || 0) + override_count
        warns    = by_level[:warn]&.size || 0
        return colorize(32, "No problems found.") if errors.zero? && warns.zero?
        return colorize(33, "No problems found (#{warns} warning(s)).") if errors.zero?

        colorize(31, "#{errors} problem(s), #{warns} warning(s).")
      end

      def colorize(code, text)
        "\e[#{code}m#{text}\e[0m"
      end
    end
  end
end
