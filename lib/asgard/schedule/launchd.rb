# frozen_string_literal: true

require "fileutils"

module Asgard
  module Schedule
    # macOS backend: each declaration becomes a launchd user agent
    # (~/Library/LaunchAgents/com.madbomber.asgard.<project>.<name>.plist).
    # launchd runs a calendar job missed while the Mac slept as soon as it
    # wakes. Implements the backend API documented in declaration.rb.
    class Launchd
      LABEL_PREFIX = "com.madbomber.asgard"

      # ---- pure helpers -----------------------------------------------------

      def self.label_prefix(project) = "#{LABEL_PREFIX}.#{Schedule.slug(project)}."

      def self.label(project, name) = "#{label_prefix(project)}#{name}"

      # One StartCalendarInterval entry per (time, weekday) pair.
      def self.calendar_intervals(at:, on: :daily)
        Schedule.calendar(at:, on:).flat_map do |entry|
          (entry[:days] || [nil]).map { |day| { "Hour" => entry[:hour], "Minute" => entry[:minute], "Weekday" => day }.compact }
        end
      end

      # Labels marked disabled in `launchctl print-disabled` output
      # ("label" => disabled, or "label" => true on older macOS).
      def self.disabled_labels(output) = output.scan(/"([^"]+)"\s*=>\s*(disabled|true)\b/).map(&:first)

      def self.plist(label:, arguments:, working_directory:, environment:, log_path:, intervals: nil, every: nil)
        dict = {
          "Label"                => label,
          "ProgramArguments"     => arguments,
          "WorkingDirectory"     => working_directory,
          "EnvironmentVariables" => environment,
          "StandardOutPath"      => log_path,
          "StandardErrorPath"    => log_path
        }
        every ? dict["StartInterval"] = every : dict["StartCalendarInterval"] = intervals

        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          #{to_xml(dict)}
          </plist>
        XML
      end

      def self.to_xml(value, indent = "")
        case value
        in Hash
          body = value.flat_map { |key, item| ["#{indent}  <key>#{escape(key)}</key>", to_xml(item, "#{indent}  ")] }
          ["#{indent}<dict>", *body, "#{indent}</dict>"].join("\n")
        in Array
          ["#{indent}<array>", *value.map { |element| to_xml(element, "#{indent}  ") }, "#{indent}</array>"].join("\n")
        in Integer
          "#{indent}<integer>#{value}</integer>"
        in true | false
          "#{indent}<#{value}/>"
        else
          "#{indent}<string>#{escape(value)}</string>"
        end
      end

      # The parts of a plist (as `plist` writes it) that say what runs and when:
      # { arguments: [String], calendar: [{ hour:, minute:, days: [Integer]|nil }], every: Integer|nil }
      def self.parse_plist(xml)
        {
          arguments: array_body(xml, "ProgramArguments").scan(%r{<string>(.*?)</string>}m).flatten.map { |text| unescape(text) },
          calendar:  calendar_entries(array_body(xml, "StartCalendarInterval").scan(%r{<dict>(.*?)</dict>}m).flatten),
          every:     xml[%r{<key>StartInterval</key>\s*<integer>(\d+)</integer>}, 1]&.to_i
        }
      end

      # StartCalendarInterval dict bodies => one entry per time, days collected.
      def self.calendar_entries(dicts)
        dicts.map { |body| parse_dict(body) }
             .group_by { |dict| dict.values_at("Hour", "Minute") }
             .map { |(hour, minute), group| calendar_entry(hour, minute, group) }
      end

      # <key>Hour</key><integer>13</integer>... => { "Hour" => 13, ... }
      def self.parse_dict(body) = body.scan(%r{<key>(\w+)</key>\s*<integer>(\d+)</integer>}).to_h { |key, num| [key, num.to_i] }

      # group: the Weekday-bearing dicts for one time; days is nil when there are none (every day).
      def self.calendar_entry(hour, minute, group)
        days = group.filter_map { |dict| dict["Weekday"] }
        { hour:, minute:, days: days.empty? ? nil : days }
      end

      # The text inside the <array> that follows <key>key</key>.
      def self.array_body(xml, key) = xml[%r{<key>#{key}</key>\s*<array>(.*?)</array>}m, 1].to_s

      # The WorkingDirectory (the project root) of a plist, or nil.
      def self.parse_directory(xml) = xml[%r{<key>WorkingDirectory</key>\s*<string>(.*?)</string>}m, 1]&.then { |text| unescape(text) }

      def self.unescape(text) = Schedule.xml_unescape(text)

      def self.escape(text) = Schedule.xml_escape(text)

      # ---- backend API ------------------------------------------------------

      def initialize(project:, root:, home: Dir.home, runner: Schedule.runner, uid: Process.uid)
        @project = project
        @root    = root
        @home    = home
        @runner  = runner
        @domain  = "gui/#{uid}"
      end

      def scheduler = "launchd"

      def label(name) = self.class.label(@project, name)

      def plist_path(name) = File.join(@home, "Library", "LaunchAgents", "#{label(name)}.plist")

      def log_path(name) = File.join(@home, "Library", "Logs", "asgard", "#{label(name)}.log")

      def files(spec, asgard:, direnv:)
        name  = spec[:name]
        every = spec[:every]
        klass = self.class
        plist = klass.plist(
          label:             label(name),
          arguments:         Schedule.program_arguments(spec[:task], spec[:args], root: @root, asgard:, direnv:),
          working_directory: @root,
          environment:       Schedule.environment(spec),
          log_path:          log_path(name),
          intervals:         every ? nil : klass.calendar_intervals(at: spec[:at], on: spec[:on]),
          every:
        )
        { plist_path(name) => plist }
      end

      def install(spec, asgard:, direnv:)
        name  = spec[:name]
        plist = plist_path(name)
        FileUtils.mkdir_p [File.dirname(plist), File.dirname(log_path(name))]
        files(spec, asgard:, direnv:).each { |path, content| File.write(path, content) }
        run! "plutil", "-lint", "-s", plist
        unload(name)
        return :stopped if stopped?(name)

        run! "launchctl", "bootstrap", @domain, plist
        :active
      end

      def uninstall(name)
        unload(name)
        run "launchctl", "enable", target(name) # clear any stop
        FileUtils.rm_f(plist_path(name))
      end

      def start(name)
        run! "launchctl", "enable", target(name)
        run! "launchctl", "bootstrap", @domain, plist_path(name) unless loaded?(name)
      end

      def stop(name)
        run! "launchctl", "disable", target(name)
        unload(name)
      end

      def trigger(name) = run!("launchctl", "kickstart", target(name))

      def installed_names
        prefix = self.class.label_prefix(@project)
        Dir.glob(plist_path("*")).map { |path| File.basename(path, ".plist").delete_prefix(prefix) }.sort
      end

      # Every asgard entry on this machine, whatever its project: [[project_slug, name], ...].
      def installed_entries
        paths = Dir.glob(File.join(@home, "Library", "LaunchAgents", "#{LABEL_PREFIX}.*.plist"))
        paths.map { |path| File.basename(path, ".plist").delete_prefix("#{LABEL_PREFIX}.").split(".", 2) }
             .select { |entry| entry.size == 2 }.sort
      end

      # { command:, schedule: } as installed, read from the plist; nil when there isn't one.
      def installed_columns(name)
        path = plist_path(name)
        return unless File.exist?(path)

        Schedule.installed_columns(**self.class.parse_plist(File.read(path)))
      end

      # The project root the job runs in, read from the plist; nil when there isn't one.
      def installed_directory(name)
        path = plist_path(name)
        self.class.parse_directory(File.read(path)) if File.exist?(path)
      end

      def status(name)
        out, ok = run("launchctl", "print", target(name))
        return { state: stopped?(name) ? :stopped : :not_loaded, last_exit: nil } unless ok

        code = out[/last exit code = (\d+)/, 1]
        { state: :active, last_exit: code }
      end

      def notes = []

      private

      def target(name) = "#{@domain}/#{label(name)}"

      def loaded?(name) = run("launchctl", "print", target(name)).last

      def stopped?(name)
        out, = run("launchctl", "print-disabled", @domain)
        self.class.disabled_labels(out).include?(label(name))
      end

      # bootout returns before the job is fully gone; bootstrapping the same
      # label too soon fails with "Input/output error", so wait for it.
      def unload(name)
        return unless loaded?(name)

        run "launchctl", "bootout", target(name)
        20.times do
          break unless loaded?(name)

          sleep 0.1
        end
      end

      def run(*argv) = @runner.call(*argv)

      def run!(*argv)
        out, ok = run(*argv)
        raise Error, "#{argv.join(' ')} failed: #{out.strip}" unless ok

        out
      end
    end
  end
end
