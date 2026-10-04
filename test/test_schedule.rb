# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "fileutils"

# Stands in for Asgard::Schedule::RUNNER: records each argv and answers
# from a table of { argv_prefix_string => [output, success?] } (longest
# matching prefix wins; unmatched commands succeed with no output).
class FakeRunner
  attr_reader :calls

  def initialize(responses = {})
    @responses = responses
    @calls     = []
  end

  def call(*argv)
    @calls << argv
    line = argv.join(" ")
    key  = @responses.keys.select { |prefix| line.start_with?(prefix) }.max_by(&:length)
    key ? @responses[key] : ["", true]
  end

  def commands = @calls.map { |cmd| cmd.join(" ") }
end

class TestScheduleDeclaration < Minitest::Test
  SD = Asgard::Schedule

  def test_parse_time
    assert_equal [7, 5], SD.parse_time("7:05")
    assert_raises(ArgumentError) { SD.parse_time("24:00") }
    assert_raises(ArgumentError) { SD.parse_time("5pm") }
  end

  def test_weekdays
    assert_nil SD.weekdays(:daily)
    assert_equal [1, 2, 3, 4, 5], SD.weekdays(:weekdays)
    assert_equal [6, 0], SD.weekdays(:weekends)
    assert_equal [5], SD.weekdays(:friday)
    assert_equal [1, 4], SD.weekdays(%i[monday thursday])
    assert_raises(ArgumentError) { SD.weekdays(:funday) }
  end

  def test_calendar_one_entry_per_time
    assert_equal [{ hour: 2, minute: 0, days: nil }, { hour: 14, minute: 0, days: nil }], SD.calendar(at: %w[02:00 14:00])
    assert_equal [{ hour: 9, minute: 15, days: [2, 4] }], SD.calendar(at: "09:15", on: %i[tuesday thursday])
  end

  def test_normalize_requires_exactly_one_of_at_or_every
    assert_raises(ArgumentError) { SD.normalize(:x) }
    assert_raises(ArgumentError) { SD.normalize(:x, at: "01:00", every: 60) }
    assert_raises(ArgumentError) { SD.normalize(:x, every: 0) }
    assert_equal({ "A" => "1" }, SD.normalize(:x, every: 60, env: { A: 1 })[:env])
  end

  def test_normalize_splits_options_shell_style
    spec = SD.normalize(:report, options: "--format md --title 'Week 39' -v", every: 60)
    assert_equal "report", spec[:task]
    assert_equal ["--format", "md", "--title", "Week 39", "-v"], spec[:args]
    assert_equal "report-format-md-title-week-39-v", spec[:name]
  end

  def test_normalize_accepts_options_as_array
    assert_equal ["--title", "Week 39"], SD.normalize(:report, options: ["--title", "Week 39"], every: 60)[:args]
  end

  def test_normalize_names
    assert_equal "sync", SD.normalize(:sync, every: 60)[:name]
    assert_equal "weekly", SD.normalize(:report, options: "--period week", every: 60, as: "weekly")[:name]
    assert_raises(ArgumentError) { SD.normalize(:report, options: "-v", every: 60, as: "bad name") }
  end

  def test_normalize_rejects_flags_in_the_task_name
    assert_raises(ArgumentError) { SD.normalize("report -v", every: 60) }
    assert_raises(ArgumentError) { SD.normalize("", every: 60) }
  end

  def test_seconds_accepts_integers_and_durations
    duration = Struct.new(:in_seconds).new(180.0)
    assert_equal 90, SD.seconds(90)
    assert_equal 180, SD.seconds(duration)
    assert_nil SD.seconds("3m")
    assert_equal 180, SD.normalize(:sync, every: duration)[:every]
    assert_raises(ArgumentError) { SD.normalize(:sync, every: "3m") }
  end

  def test_slug
    assert_equal "my-app", SD.slug("My_App")
  end

  def test_command_line_requotes_args
    assert_equal "asgard report --title Week\\ 39", SD.command_line("report", ["--title", "Week 39"])
  end

  def test_command_from_arguments
    assert_equal "asgard sync --fast", Asgard::Schedule.command_from_arguments(%w[/opt/bin/asgard sync --fast])
    assert_equal "asgard sync", Asgard::Schedule.command_from_arguments(%w[/opt/homebrew/bin/direnv exec /proj asgard sync])
    assert_equal "asgard", Asgard::Schedule.command_from_arguments([])
    assert_equal "asgard sync", Asgard::Schedule.command_from_arguments(["C:\\Ruby\\bin\\asgard.bat", "sync"])
  end

  def test_describe_calendar_groups_by_days
    entries = [{ hour: 17, minute: 0, days: [1, 2, 3, 4, 5] }, { hour: 9, minute: 0, days: [6] }, { hour: 8, minute: 0, days: nil }]
    assert_equal "17:00 weekdays; 09:00 saturday; 08:00 daily", Asgard::Schedule.describe_calendar(entries)
  end

  def test_describe
    assert_equal "every 60s", SD.describe(every: 60)
    assert_equal "17:30 weekdays", SD.describe(at: "17:30", on: :weekdays)
  end

  def test_environment_merges_path_and_env
    assert_equal({ "PATH" => "/bin", "A" => "1" }, SD.environment({ env: { "A" => "1" } }, "/bin"))
  end

  def test_which
    Dir.mktmpdir do |dir|
      tool = File.join(dir, "tool")
      File.write(tool, "")
      assert_nil SD.which("tool", dir)
      File.chmod(0o755, tool)
      assert_equal tool, SD.which("tool", "/nonexistent:#{dir}")
    end
  end

  def test_which_finds_a_windows_batch_stub
    Dir.mktmpdir do |dir|
      stub = File.join(dir, "asgard.bat")
      File.write(stub, "")
      File.chmod(0o755, stub)
      assert_equal stub, SD.which("asgard", dir)
    end
  end

  def test_program_arguments
    assert_equal %w[/bin/asgard sync], SD.program_arguments(:sync, root: "/r", asgard: "/bin/asgard")
    assert_equal ["/bin/asgard", "report", "--title", "Week 39"],
                 SD.program_arguments("report", ["--title", "Week 39"], root: "/r", asgard: "/bin/asgard")
    assert_equal %w[/bin/direnv exec /r asgard report -v],
                 SD.program_arguments("report", ["-v"], root: "/r", asgard: "/bin/asgard", direnv: "/bin/direnv")
  end

  def test_runner_reports_missing_commands_as_failure
    out, ok = SD::RUNNER.call("definitely-not-a-command-xyz")
    refute ok
    refute_empty out
  end
end

class TestScheduleLaunchd < Minitest::Test
  def spec(**) = Asgard::Schedule.normalize(:demo, **)

  def backend(home, runner = FakeRunner.new) = Asgard::Schedule::Launchd.new(project: "My App", root: "/proj", home:, runner:, uid: 501)

  def test_label_slugs_the_project
    assert_equal "com.madbomber.asgard.my-app.sync", Asgard::Schedule::Launchd.label("My_App", :sync)
  end

  def test_calendar_intervals_cross_times_and_days
    assert_equal [{ "Hour" => 2, "Minute" => 0 }], Asgard::Schedule::Launchd.calendar_intervals(at: "02:00")
    assert_equal 4, Asgard::Schedule::Launchd.calendar_intervals(at: %w[09:00 17:00], on: %i[monday friday]).size
  end

  def test_disabled_labels
    output = <<~OUT
      \tdisabled services = {
      \t\t"com.madbomber.asgard.temp.demo" => disabled
      \t\t"com.madbomber.asgard.temp.eod" => enabled
      \t\t"com.example.old" => true
      \t\t"com.example.other" => false
      \t}
    OUT
    assert_equal %w[com.madbomber.asgard.temp.demo com.example.old], Asgard::Schedule::Launchd.disabled_labels(output)
  end

  def test_plist_is_valid_and_escaped
    xml = Asgard::Schedule::Launchd.plist(
      label: "com.madbomber.asgard.demo.sync", arguments: %w[/bin/asgard sync],
      working_directory: "/tmp/a&b", environment: { "PATH" => "/bin" },
      log_path: "/tmp/sync.log", intervals: Asgard::Schedule::Launchd.calendar_intervals(at: "17:30", on: :weekdays)
    )
    assert_includes xml, "<string>/tmp/a&amp;b</string>"
    assert_includes xml, "<key>StartCalendarInterval</key>"
    _, status = Open3.capture2("plutil", "-lint", "-s", "-", stdin_data: xml) if system("which -s plutil")
    assert status.success?, "plutil rejected:\n#{xml}" if status
  end

  def test_plist_with_start_interval
    xml = Asgard::Schedule::Launchd.plist(label: "l", arguments: ["/a"], working_directory: "/", environment: {},
                                          log_path: "/tmp/l.log", every: 3600)
    assert_includes xml, "<key>StartInterval</key>\n  <integer>3600</integer>"
    refute_includes xml, "StartCalendarInterval"
  end

  def test_paths_live_under_home
    b = backend("/h")
    assert_equal "/h/Library/LaunchAgents/com.madbomber.asgard.my-app.demo.plist", b.plist_path("demo")
    assert_equal "/h/Library/Logs/asgard/com.madbomber.asgard.my-app.demo.log", b.log_path("demo")
  end

  def test_install_writes_plist_and_bootstraps
    Dir.mktmpdir do |home|
      runner = FakeRunner.new("launchctl print gui" => ["", false])
      state  = backend(home, runner).install(spec(every: 60), asgard: "/bin/asgard", direnv: nil)
      assert_equal :active, state
      assert File.exist?(File.join(home, "Library/LaunchAgents/com.madbomber.asgard.my-app.demo.plist"))
      assert(runner.commands.any? { |cmd| cmd.start_with?("launchctl bootstrap gui/501 ") })
    end
  end

  def test_install_keeps_a_stopped_entry_stopped
    Dir.mktmpdir do |home|
      runner = FakeRunner.new(
        "launchctl print gui"      => ["", false],
        "launchctl print-disabled" => [%(\t"com.madbomber.asgard.my-app.demo" => disabled\n), true]
      )
      assert_equal :stopped, backend(home, runner).install(spec(every: 60), asgard: "/bin/asgard", direnv: nil)
      refute(runner.commands.any? { |cmd| cmd.include?("bootstrap") })
    end
  end

  def test_install_raises_on_launchctl_failure
    Dir.mktmpdir do |home|
      runner = FakeRunner.new("launchctl print gui" => ["", false], "launchctl bootstrap" => ["Bootstrap failed: 5", false])
      assert_raises(Asgard::Schedule::Error) { backend(home, runner).install(spec(every: 60), asgard: "/a", direnv: nil) }
    end
  end

  def test_stop_and_start
    runner = FakeRunner.new("launchctl print gui" => ["", false])
    b = backend("/h", runner)
    b.stop("demo")
    b.start("demo")
    assert_equal ["launchctl disable gui/501/com.madbomber.asgard.my-app.demo",
                  "launchctl print gui/501/com.madbomber.asgard.my-app.demo",
                  "launchctl enable gui/501/com.madbomber.asgard.my-app.demo",
                  "launchctl print gui/501/com.madbomber.asgard.my-app.demo",
                  "launchctl bootstrap gui/501 /h/Library/LaunchAgents/com.madbomber.asgard.my-app.demo.plist"], runner.commands
  end

  def test_status
    active = FakeRunner.new("launchctl print gui" => ["state = not running\n\tlast exit code = 0\n", true])
    assert_equal({ state: :active, last_exit: "0" }, backend("/h", active).status("demo"))

    never = FakeRunner.new("launchctl print gui" => ["last exit code = (never exited)\n", true])
    assert_equal({ state: :active, last_exit: nil }, backend("/h", never).status("demo"))

    stopped = FakeRunner.new("launchctl print gui"      => ["", false],
                             "launchctl print-disabled" => [%("com.madbomber.asgard.my-app.demo" => disabled), true])
    assert_equal :stopped, backend("/h", stopped).status("demo")[:state]
  end

  def test_installed_entries_spans_projects
    Dir.mktmpdir do |home|
      dir = File.join(home, "Library/LaunchAgents")
      FileUtils.mkdir_p(dir)
      %w[com.madbomber.asgard.my-app.b com.madbomber.asgard.other.c.d com.example.unrelated.x].each do |label|
        File.write(File.join(dir, "#{label}.plist"), "")
      end
      assert_equal [["my-app", "b"], ["other", "c.d"]], backend(home).installed_entries
    end
  end

  # What installed_columns reads back must match what the declaration lists.
  ROUND_TRIPS = [
    { at: "13:30", on: :friday },
    { at: "17:00", on: :weekdays },
    { at: %w[10:00 11:00 12:00 13:00], on: :weekdays },
    { at: %w[09:00 18:30], on: %i[monday thursday] },
    { at: "06:15" },
    { every: 90 },
    { at: "08:00", options: "--period week --title 'Week End'", as: "demo" }
  ].freeze

  def round_trip(home, **settings)
    declared = spec(**settings)
    backend(home).files(declared, asgard: "/opt/bin/asgard", direnv: nil).each do |path, content|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    [backend(home).installed_columns("demo"), Asgard::Schedule.list_columns(declared)]
  end

  def test_installed_columns_round_trip
    ROUND_TRIPS.each do |settings|
      Dir.mktmpdir do |home|
        read, declared = round_trip(home, **settings)
        assert_equal declared, read, settings.inspect
      end
    end
  end

  def test_installed_columns_drops_the_direnv_wrapper
    Dir.mktmpdir do |home|
      declared = spec(at: "17:00")
      backend(home).files(declared, asgard: "/opt/bin/asgard", direnv: "/opt/homebrew/bin/direnv").each do |path, content|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      assert_equal "asgard demo", backend(home).installed_columns("demo")[:command]
    end
  end

  def test_installed_directory
    Dir.mktmpdir do |home|
      round_trip(home, at: "17:00")
      assert_equal "/proj", backend(home).installed_directory("demo")
      assert_nil backend(home).installed_directory("nope")
    end
  end

  def test_installed_columns_is_nil_without_job_files
    Dir.mktmpdir { |home| assert_nil backend(home).installed_columns("nope") }
  end

  def test_installed_names
    Dir.mktmpdir do |home|
      dir = File.join(home, "Library/LaunchAgents")
      FileUtils.mkdir_p(dir)
      %w[com.madbomber.asgard.my-app.b com.madbomber.asgard.my-app.a com.madbomber.asgard.other.c].each do |label|
        File.write(File.join(dir, "#{label}.plist"), "")
      end
      assert_equal %w[a b], backend(home).installed_names
    end
  end
end

class TestScheduleSystemd < Minitest::Test
  def spec(**) = Asgard::Schedule.normalize(:demo, **)

  def backend(home, runner = FakeRunner.new, env: {})
    Asgard::Schedule::Systemd.new(project: "My App", root: "/proj", home:, runner:, env:, user: "dewayne")
  end

  # What installed_columns reads back must match what the declaration lists.
  ROUND_TRIPS = [
    { at: "13:30", on: :friday },
    { at: "17:00", on: :weekdays },
    { at: %w[10:00 11:00 12:00 13:00], on: :weekdays },
    { at: %w[09:00 18:30], on: %i[monday thursday] },
    { at: "06:15" },
    { every: 90 },
    { at: "08:00", options: "--period week --title 'Week End'", as: "demo" }
  ].freeze

  def round_trip(home, **settings)
    declared = spec(**settings)
    backend(home).files(declared, asgard: "/opt/bin/asgard", direnv: nil).each do |path, content|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    [backend(home).installed_columns("demo"), Asgard::Schedule.list_columns(declared)]
  end

  def test_installed_columns_round_trip
    ROUND_TRIPS.each do |settings|
      Dir.mktmpdir do |home|
        read, declared = round_trip(home, **settings)
        assert_equal declared, read, settings.inspect
      end
    end
  end

  def test_installed_columns_drops_the_direnv_wrapper
    Dir.mktmpdir do |home|
      declared = spec(at: "17:00")
      backend(home).files(declared, asgard: "/opt/bin/asgard", direnv: "/opt/homebrew/bin/direnv").each do |path, content|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      assert_equal "asgard demo", backend(home).installed_columns("demo")[:command]
    end
  end

  def test_installed_directory
    Dir.mktmpdir do |home|
      round_trip(home, at: "17:00")
      assert_equal "/proj", backend(home).installed_directory("demo")
      assert_nil backend(home).installed_directory("nope")
    end
  end

  def test_installed_columns_is_nil_without_job_files
    Dir.mktmpdir { |home| assert_nil backend(home).installed_columns("nope") }
  end

  def test_unit_slugs_the_project
    assert_equal "asgard.my-app.sync", Asgard::Schedule::Systemd.unit("My_App", :sync)
  end

  def test_on_calendar
    assert_equal "*-*-* 02:00:00", Asgard::Schedule::Systemd.on_calendar({ hour: 2, minute: 0, days: nil })
    assert_equal "Mon,Tue,Wed,Thu,Fri *-*-* 17:30:00",
                 Asgard::Schedule::Systemd.on_calendar({ hour: 17, minute: 30, days: [1, 2, 3, 4, 5] })
    assert_equal "Sat,Sun *-*-* 09:05:00", Asgard::Schedule::Systemd.on_calendar({ hour: 9, minute: 5, days: [6, 0] })
  end

  def test_quote_escapes_backslash_quote_percent_and_dollar
    assert_equal %("a b"), Asgard::Schedule::Systemd.quote("a b")
    assert_equal %("say \\"hi\\" 100%% $$HOME c:\\\\x"), Asgard::Schedule::Systemd.quote(%(say "hi" 100% $HOME c:\\x))
  end

  def test_service_unit
    unit = Asgard::Schedule::Systemd.service_unit(
      description: "asgard report --title Week\\ End (proj)", arguments: ["/bin/asgard", "report", "--title", "Week End"],
      working_directory: "/proj", environment: { "PATH" => "/usr/bin", "RATE" => "5%" }, log_path: "/log/x.log"
    )
    assert_includes unit, "Type=oneshot\n"
    assert_includes unit, %(ExecStart="/bin/asgard" "report" "--title" "Week End"\n)
    assert_includes unit, %(Environment="PATH=/usr/bin"\nEnvironment="RATE=5%%"\n)
    assert_includes unit, "WorkingDirectory=/proj\n"
    assert_includes unit, "StandardOutput=append:/log/x.log\nStandardError=append:/log/x.log\n"
  end

  def test_timer_unit_calendar
    unit = Asgard::Schedule::Systemd.timer_unit(description: "d", service: "s.service",
                                                calendar: Asgard::Schedule.calendar(at: %w[08:00 16:00], on: :friday))
    assert_includes unit, "OnCalendar=Fri *-*-* 08:00:00\nOnCalendar=Fri *-*-* 16:00:00\nPersistent=true\n"
    assert_includes unit, "Unit=s.service\n"
    assert_includes unit, "WantedBy=timers.target\n"
  end

  def test_timer_unit_every
    unit = Asgard::Schedule::Systemd.timer_unit(description: "d", service: "s.service", every: 180)
    assert_includes unit, "OnActiveSec=180\nOnUnitActiveSec=180\n"
    refute_includes unit, "OnCalendar"
  end

  def test_parse_show
    assert_equal({ "ExecMainStatus" => "0", "ExecMainExitTimestampMonotonic" => "123" },
                 Asgard::Schedule::Systemd.parse_show("ExecMainStatus=0\nExecMainExitTimestampMonotonic=123\n"))
  end

  def test_paths_follow_xdg
    b = backend("/h")
    assert_equal "/h/.config/systemd/user/asgard.my-app.demo.timer", b.timer_path("demo")
    assert_equal "/h/.local/state/asgard/asgard.my-app.demo.log", b.log_path("demo")
    x = backend("/h", env: { "XDG_CONFIG_HOME" => "/cfg", "XDG_STATE_HOME" => "/st" })
    assert_equal "/cfg/systemd/user/asgard.my-app.demo.service", x.service_path("demo")
    assert_equal "/st/asgard/asgard.my-app.demo.log", x.log_path("demo")
  end

  def test_install_writes_units_and_enables_timer
    Dir.mktmpdir do |home|
      runner = FakeRunner.new
      assert_equal :active, backend(home, runner).install(spec(at: "17:30", on: :weekdays), asgard: "/bin/asgard", direnv: nil)
      assert File.exist?(File.join(home, ".config/systemd/user/asgard.my-app.demo.service"))
      assert File.exist?(File.join(home, ".config/systemd/user/asgard.my-app.demo.timer"))
      assert_equal ["systemctl --user daemon-reload",
                    "systemctl --user enable asgard.my-app.demo.timer",
                    "systemctl --user restart asgard.my-app.demo.timer"], runner.commands
    end
  end

  def test_install_keeps_a_stopped_entry_stopped
    Dir.mktmpdir do |home|
      b = backend(home)
      b.install(spec(every: 60), asgard: "/a", direnv: nil)
      runner = FakeRunner.new("systemctl --user is-enabled" => ["disabled", false])
      assert_equal :stopped, backend(home, runner).install(spec(every: 60), asgard: "/a", direnv: nil)
      refute(runner.commands.any? { |cmd| cmd.include?(" enable ") })
    end
  end

  def test_install_raises_on_systemctl_failure
    Dir.mktmpdir do |home|
      runner = FakeRunner.new("systemctl --user enable" => ["Failed to connect to bus", false])
      error  = assert_raises(Asgard::Schedule::Error) { backend(home, runner).install(spec(every: 60), asgard: "/a", direnv: nil) }
      assert_includes error.message, "Failed to connect to bus"
    end
  end

  def test_start_stop_trigger
    runner = FakeRunner.new
    b = backend("/h", runner)
    b.stop("demo")
    b.start("demo")
    b.trigger("demo")
    assert_equal ["systemctl --user disable --now asgard.my-app.demo.timer",
                  "systemctl --user enable --now asgard.my-app.demo.timer",
                  "systemctl --user start --no-block asgard.my-app.demo.service"], runner.commands
  end

  def test_uninstall_removes_units
    Dir.mktmpdir do |home|
      b = backend(home)
      b.install(spec(every: 60), asgard: "/a", direnv: nil)
      b.uninstall("demo")
      assert_empty b.installed_names
    end
  end

  def test_status
    ran = FakeRunner.new("systemctl --user show" => ["ExecMainStatus=3\nExecMainExitTimestampMonotonic=99\n", true])
    assert_equal({ state: :active, last_exit: "3" }, backend("/h", ran).status("demo"))

    never = FakeRunner.new("systemctl --user show" => ["ExecMainStatus=0\nExecMainExitTimestampMonotonic=0\n", true])
    assert_equal({ state: :active, last_exit: nil }, backend("/h", never).status("demo"))

    stopped = FakeRunner.new("systemctl --user is-active" => ["", false], "systemctl --user is-enabled" => ["", false])
    assert_equal :stopped, backend("/h", stopped).status("demo")[:state]
  end

  def test_notes_mention_linger_only_when_off
    off = FakeRunner.new("loginctl" => ["no\n", true])
    assert_match(/enable-linger/, backend("/h", off).notes.first)
    on = FakeRunner.new("loginctl" => ["yes\n", true])
    assert_empty backend("/h", on).notes
  end
end

class TestScheduleRegistry < Minitest::Test
  def setup    = Asgard::Schedule.declarations.clear
  def teardown = Asgard::Schedule.declarations.clear

  def test_tasks_schedule_declares_an_entry
    Tasks.schedule :tree, every: 60
    assert_equal "tree", Asgard::Schedule.declarations["tree"][:task]
  end

  def test_redeclaring_the_same_entry_is_a_no_op
    2.times { Tasks.schedule :tree, every: 60 }
    assert_equal 1, Asgard::Schedule.declarations.size
  end

  def test_redeclaring_a_name_differently_raises
    Tasks.schedule :tree, every: 60
    assert_raises(ArgumentError) { Tasks.schedule :tree, every: 120 }
  end

  def test_backend_class_by_platform
    assert_equal Asgard::Schedule::Launchd, Asgard::Schedule.backend_class("arm64-darwin25", scheduler: nil)
    assert_equal Asgard::Schedule::Systemd, Asgard::Schedule.backend_class("x86_64-linux", scheduler: nil)
    assert_equal Asgard::Schedule::Windows, Asgard::Schedule.backend_class("x64-mingw-ucrt", scheduler: nil)
    assert_equal Asgard::Schedule::Windows, Asgard::Schedule.backend_class("x64-mswin64", scheduler: nil)
    assert_raises(Asgard::Schedule::Error) { Asgard::Schedule.backend_class("x86_64-freebsd", scheduler: nil) }
  end

  def test_runner_defaults_to_runner_constant
    Asgard::Schedule.runner = FakeRunner.new
    refute_equal Asgard::Schedule::RUNNER, Asgard::Schedule.runner
    Asgard::Schedule.runner = nil
    assert_equal Asgard::Schedule::RUNNER, Asgard::Schedule.runner
  end

  def test_schedule_error_is_an_asgard_error
    assert_operator Asgard::Schedule::Error, :<, Asgard::Error
  end
end

# Drives `asgard schedule ...` end to end in a temp project, with HOME and
# PATH pointed at temp dirs and a FakeRunner standing in for
# launchctl/systemctl — whichever backend this platform selects.
class TestScheduleCommands < Minitest::Test
  def setup
    @saved   = ENV.to_h.slice("HOME", "PATH", "XDG_CONFIG_HOME", "XDG_STATE_HOME")
    @tmp     = Dir.mktmpdir
    @project = File.join(@tmp, "proj")
    @bin     = File.join(@tmp, "bin")
    FileUtils.mkdir_p [@project, @bin]
    File.write(File.join(@project, ".loki"), "")
    File.write(File.join(@bin, "asgard"), "")
    File.chmod(0o755, File.join(@bin, "asgard"))
    ENV["HOME"] = @tmp
    ENV["PATH"] = @bin
    ENV.delete("XDG_CONFIG_HOME")
    ENV.delete("XDG_STATE_HOME")
    # "not loaded" keeps launchd from waiting on bootout
    @runner = FakeRunner.new("launchctl print gui" => ["", false])
    Asgard::Schedule.runner = @runner
    Asgard::Schedule.declarations.clear
  end

  def teardown
    @saved.each { |k, v| ENV[k] = v }
    Asgard::Schedule.runner = nil
    Asgard::Schedule.declarations.clear
    FileUtils.rm_rf(@tmp)
  end

  # Commands dedups by task name per run, like any Asgard::Base class; each
  # call here stands for a separate `asgard schedule ...` process.
  def schedule(*argv)
    Asgard::Schedule::Commands._reset_ran!
    Dir.chdir(@project) { Asgard::Schedule::Commands.start(argv) }
  end

  def backend = Asgard::Schedule.backend_class.new(project: "proj", root: File.realpath(@project))

  def test_asgard_schedule_maps_to_the_subcommand
    Asgard::Schedule::Commands._reset_ran! # each task runs once per process; an earlier test may have run `list`
    out, = capture_io { Dir.chdir(@project) { Tasks.start(%w[schedule list]) } }
    assert_match "No scheduled tasks installed for proj", out
    assert_match "asgard schedule list --all", out
  end

  def test_subcommand_usage_reads_schedule_not__schedule
    out, = capture_io { Asgard::Schedule::Commands.start(%w[help]) }
    assert_match " schedule install", out
    refute_match(/ _schedule /, out)
  end

  def test_install_without_declarations_aborts
    _, err = capture_io { assert_raises(SystemExit) { schedule("install") } }
    assert_match "No schedules declared", err
  end

  def test_install_rejects_unknown_tasks
    Tasks.schedule :no_such_task, every: 60
    _, err = capture_io { assert_raises(SystemExit) { schedule("install") } }
    assert_match "no such task(s): no_such_task", err
  end

  def test_install_list_and_remove
    Tasks.schedule :tree, every: 60
    out, = capture_io { schedule("install") }
    assert_match "installed tree: asgard tree (every 60s)", out
    assert_equal ["tree"], backend.installed_names

    out, = capture_io { schedule("list") }
    assert_match(/NAME\s+│\s*COMMAND\s+│\s*SCHEDULE\s+│\s*STATE\s+│\s*LAST EXIT/, out)
    assert_match(/│ tree\s+│ asgard tree\s+│ every 60s/, out)
    assert_match(/^Logs: .*asgard schedule log NAME/, out)

    out, = capture_io { schedule("remove") }
    assert_match "removed tree", out
    assert_empty backend.installed_names
  end

  def test_install_drops_undeclared_entries
    Tasks.schedule :tree, every: 60
    Tasks.schedule :tree, options: "--x", every: 60, as: "old"
    capture_io { schedule("install") }
    Asgard::Schedule.declarations.delete("old")

    out, = capture_io { schedule("install") }
    assert_match "removed old", out
    assert_equal ["tree"], backend.installed_names
  end

  def test_list_all_shows_other_projects_and_runs_outside_a_project
    Tasks.schedule :tree, every: 60
    capture_io { schedule("install") }
    Asgard::Schedule.declarations.clear
    Tasks.schedule :tree, every: 60, as: "nightly"
    spec  = Asgard::Schedule.declarations["nightly"]
    other = Asgard::Schedule.backend_class.new(project: "elsewhere", root: @tmp)
    other.install(spec, asgard: File.join(@bin, "asgard"), direnv: nil)
    Asgard::Schedule.declarations.clear
    Tasks.schedule :tree, every: 60

    out, = capture_io { schedule("list") }
    refute_match "elsewhere", out

    out, = capture_io { schedule("list", "--all") }
    assert_equal ["Project: elsewhere (#{@tmp})", "Project: proj (#{File.realpath(@project)})"], out.lines.grep(/^Project:/).map(&:chomp)
    assert_match(/^Project: elsewhere .*\n┌.*?│ nightly\s+│ asgard tree\s+│ every 60s/m, out)
    assert_match(/^Project: proj .*\n┌.*?│ tree\s+│ asgard tree/m, out)
    assert_equal 1, out.scan(/^Logs:/).size

    File.delete(File.join(@project, ".loki"))
    out, = capture_io { schedule("list") }
    assert_match "Project: elsewhere", out
  end

  def test_list_marks_undeclared_entries
    Tasks.schedule :tree, every: 60
    capture_io { schedule("install") }
    Asgard::Schedule.declarations.clear
    out, = capture_io { schedule("list") }
    assert_match "no longer declared", out
  end

  def test_preview_prints_job_files_without_installing
    Tasks.schedule :tree, at: "17:30", on: :weekdays
    out, = capture_io { schedule("preview") }
    assert_match "asgard tree (17:30 weekdays)", out
    assert_empty backend.installed_names
  end

  def test_preview_warns_when_envrc_exists_but_direnv_is_missing
    File.write(File.join(@project, ".envrc"), "")
    Tasks.schedule :tree, every: 60
    _, err = capture_io { schedule("preview") }
    assert_match "direnv is not on PATH", err
  end

  def test_install_aborts_when_asgard_is_not_on_path
    ENV["PATH"] = @tmp
    Tasks.schedule :tree, every: 60
    _, err = capture_io { assert_raises(SystemExit) { schedule("install") } }
    assert_match "asgard is not on PATH", err
  end

  def test_stop_start_and_trigger_require_an_installed_entry
    %w[stop trigger].each do |cmd|
      _, err = capture_io { assert_raises(SystemExit) { schedule(cmd, "tree") } }
      assert_match "tree is not installed", err
    end
    _, err = capture_io { assert_raises(SystemExit) { schedule("start", "tree") } }
    assert_match "neither declared nor installed", err
  end

  def test_stop_start_trigger
    Tasks.schedule :tree, every: 60
    capture_io { schedule("install") }
    assert_match "stopped tree", capture_io { schedule("stop", "tree") }.first
    assert_match "started tree", capture_io { schedule("start", "tree") }.first
    assert_match "triggered tree", capture_io { schedule("trigger", "tree") }.first
  end

  def test_start_an_installed_entry_that_is_no_longer_declared
    Tasks.schedule :tree, every: 60
    capture_io { schedule("install") }
    Asgard::Schedule.declarations.clear
    out, err = capture_io { schedule("start", "tree") }
    assert_match "no longer declared", err
    assert_match "started tree", out
  end

  # Installs `tree` under project "elsewhere" (not loaded here) and, optionally, under this project too.
  def install_elsewhere(also_here: false)
    Tasks.schedule :tree, every: 60
    capture_io { schedule("install") } if also_here
    spec = Asgard::Schedule.declarations["tree"]
    Asgard::Schedule.backend_class.new(project: "elsewhere", root: @tmp).install(spec, asgard: File.join(@bin, "asgard"), direnv: nil)
    Asgard::Schedule.declarations.clear
  end

  # Did a stop (launchctl disable / systemctl disable) reach this label or unit?
  def disabled?(name) = @runner.commands.any? { |line| line.include?(name) && line.include?("disable") }

  def test_commands_reach_entries_of_other_projects
    install_elsewhere
    other = Asgard::Schedule.backend_class.new(project: "elsewhere", root: @tmp)

    assert_match "stopped tree", capture_io { schedule("stop", "tree") }.first
    assert disabled?("asgard.elsewhere.tree"), @runner.commands.inspect
    _, err = capture_io { schedule("start", "tree") }
    assert_match "belongs to another project", err
    assert_match "triggered elsewhere/tree", capture_io { schedule("trigger", "elsewhere/tree") }.first

    FileUtils.mkdir_p(File.dirname(other.log_path("tree")))
    File.write(other.log_path("tree"), "other ran\n")
    assert_equal "other ran\n", capture_io { schedule("log", "tree") }.first
  end

  def test_same_name_in_two_projects_needs_the_project_prefix
    install_elsewhere(also_here: true)
    Asgard::Schedule.declarations.clear

    assert_match "stopped tree", capture_io { schedule("stop", "tree") }.first # this project wins a bare name
    assert disabled?("asgard.proj.tree")
    refute disabled?("asgard.elsewhere.tree")
    assert_match "stopped elsewhere/tree", capture_io { schedule("stop", "elsewhere/tree") }.first
    assert disabled?("asgard.elsewhere.tree")
  end

  def test_a_bare_name_found_in_several_other_projects_is_ambiguous
    install_elsewhere
    spec = Asgard::Schedule.normalize(:tree, every: 60)
    Asgard::Schedule.backend_class.new(project: "third", root: @tmp).install(spec, asgard: File.join(@bin, "asgard"), direnv: nil)

    _, err = capture_io { assert_raises(SystemExit) { schedule("stop", "tree") } }
    assert_match "tree is in several projects (elsewhere, third); name one as project/tree", err
  end

  def test_log
    Tasks.schedule :tree, every: 60
    _, err = capture_io { schedule("log", "tree") }
    assert_match "has no log yet", err

    path = backend.log_path("tree")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "ran ok\n")
    out, = capture_io { schedule("log", "tree") }
    assert_equal "ran ok\n", out
  end

  def test_remove_with_nothing_installed
    out, = capture_io { schedule("remove") }
    assert_match "No scheduled tasks installed for proj.", out
  end
end

class TestScheduleTable < Minitest::Test
  SD = Asgard::Schedule

  ROWS = [{ name: "a", command: "asgard a", schedule: "17:00 weekdays", state: "active", last_exit: "0" },
          { name: "long_name", command: "asgard b", schedule: "13:30 friday", state: "stopped", last_exit: "-" }].freeze

  LONG = [{ name: "status_shell_hourly", command: "asgard status shell_hourly",
            schedule: "10:00-17:00 hourly weekdays", state: "active", last_exit: "never run" }].freeze

  def test_describe_compact_collapses_hourly_runs
    hours = (10..17).map { |h| format("%02d:00", h) }
    assert_equal "10:00-17:00 hourly weekdays", SD.describe_compact(at: hours, on: :weekdays)
    assert_equal "09:00, 13:30 friday", SD.describe_compact(at: %w[09:00 13:30], on: :friday)
    assert_equal "every 60s", SD.describe_compact(every: 60)
  end

  def test_table_draws_header_and_one_line_per_row
    out = SD::Table.new(ROWS, color: false, width: 100).render
    assert_match(/NAME\s+│\s*COMMAND\s+│\s*SCHEDULE\s+│\s*STATE\s+│\s*LAST EXIT/, out)
    assert_match(/long_name\s+│\s*asgard b/, out)
    refute_includes out, "\e["
  end

  def test_table_wraps_long_cells_and_keeps_short_ones_whole
    wide   = SD::Table.new(LONG, color: false, width: 140).render
    narrow = SD::Table.new(LONG, color: false, width: 95).render
    assert_operator narrow.lines.size, :>, wide.lines.size
    assert(narrow.lines.all? { |line| line.chomp.length <= 95 })
    assert_includes narrow, "status_shell_hourly"
    assert_includes narrow, "never run"
  end

  def test_column_widths_shrink_only_flexible_columns
    roomy = SD::Table.new(LONG, color: false, width: 200)
    tight = SD::Table.new(LONG, color: false, width: 90)
    assert_equal roomy.column_widths.values_at(0, 3, 4), tight.column_widths.values_at(0, 3, 4)
    assert_operator tight.column_widths[1], :<, roomy.column_widths[1]
    assert_operator tight.column_widths[2], :<, roomy.column_widths[2]
    assert_equal 90, tight.total_width
  end

  def test_table_colors_only_on_request
    rows = [{ name: "a", command: "c", schedule: "s", state: "active", last_exit: "1" }]
    assert_includes SD::Table.new(rows, color: true, width: 100).render, "\e[31m1"
  end

  def test_terminal_width_for_non_tty_uses_columns_then_default
    io = StringIO.new
    assert_equal 120, SD::Table.terminal_width(io, env: {})
    assert_equal 90,  SD::Table.terminal_width(io, env: { "COLUMNS" => "90" })
    assert_equal 120, SD::Table.terminal_width(io, env: { "COLUMNS" => "wide" })
  end
end

# Stands in for the `crontab` command: `crontab -l` prints what was last
# installed (or fails like cron does when there is none), `crontab FILE`
# installs FILE. Anything else really runs.
class FakeCrontab
  attr_accessor :text
  attr_reader :calls

  def initialize(text = nil, list_error: nil)
    @text       = text
    @list_error = list_error
    @calls      = []
  end

  def call(*argv)
    @calls << argv
    case argv
    in ["crontab", "-l"] then list
    in ["crontab", path]  then install(path)
    else Asgard::Schedule::RUNNER.call(*argv)
    end
  end

  private

  def list
    return [@list_error, false] if @list_error

    @text ? [@text, true] : ["crontab: no crontab for dewayne\n", false]
  end

  def install(path)
    @text = File.read(path)
    ["", true]
  end
end

class TestScheduleCron < Minitest::Test
  CRON = Asgard::Schedule::Cron

  def spec(**) = Asgard::Schedule.normalize(:demo, **)

  def setup = @home = Dir.mktmpdir

  def teardown = FileUtils.rm_rf(@home)

  def backend(crontab = FakeCrontab.new, home: @home) = CRON.new(project: "My App", root: "/proj", home:, runner: crontab, env: {})

  def install(crontab, **settings) = backend(crontab).install(spec(**settings), asgard: "/opt/bin/asgard", direnv: nil)

  # What installed_columns reads back must match what the declaration lists.
  ROUND_TRIPS = [
    { at: "13:30", on: :friday },
    { at: "17:00", on: :weekdays },
    { at: %w[10:00 11:00 12:00 13:00], on: :weekdays },
    { at: %w[09:00 18:30], on: %i[monday thursday] },
    { at: "06:15" },
    { every: 300 },
    { every: 21_600 },
    { at: "08:00", options: "--period week --title 'Week End 50%'", as: "demo" }
  ].freeze

  def test_calendar_fields
    assert_equal "30 17 * * 1,2,3,4,5", CRON.calendar_fields({ hour: 17, minute: 30, days: [1, 2, 3, 4, 5] })
    assert_equal "5 2 * * *", CRON.calendar_fields({ hour: 2, minute: 5, days: nil })
  end

  def test_interval_fields
    assert_equal "*/1 * * * *",  CRON.interval_fields(60)
    assert_equal "*/15 * * * *", CRON.interval_fields(900)
    assert_equal "0 */1 * * *",  CRON.interval_fields(3600)
    assert_equal "0 */6 * * *",  CRON.interval_fields(21_600)
    assert_equal "0 */24 * * *", CRON.interval_fields(86_400)
  end

  def test_interval_fields_rejects_what_cron_cannot_say
    [30, 90, 420, 7200 + 60, 18_000, 172_800].each do |seconds|
      assert_raises(Asgard::Schedule::Error, seconds.to_s) { CRON.interval_fields(seconds) }
    end
  end

  def test_command_escapes_percent_and_quotes_paths
    command = CRON.command(arguments: ["/bin/asgard", "say", "100%"], working_directory: "/my proj",
                           environment: { "PATH" => "/bin" }, log_path: "/log/x.log")
    assert_equal 'cd /my\ proj && env PATH\=/bin /bin/asgard say 100\\\\% >> /log/x.log 2>&1', command
    refute_match(/[^\\]%/, command)
  end

  def test_block_and_parse_blocks_round_trip
    text = CRON.block("proj.a", ["0 1 * * * x"]) + CRON.stopped_block("proj.b", ["0 2 * * * y", "0 3 * * * z"])
    assert_equal({ "proj.a" => { stopped: false, jobs: ["0 1 * * * x"] },
                   "proj.b" => { stopped: true, jobs: ["0 2 * * * y", "0 3 * * * z"] } }, CRON.parse_blocks(text))
  end

  def test_with_block_replaces_in_place_and_appends_otherwise
    mine = CRON.block("proj.a", ["old"])
    text = "MAILTO=me\n#{mine}0 0 * * * other\n"
    replaced = CRON.with_block(text, "proj.a", CRON.block("proj.a", ["new"]))
    assert_equal "MAILTO=me\n#{CRON.block('proj.a', ['new'])}0 0 * * * other\n", replaced
    assert_equal "0 0 * * * other\n#{mine}", CRON.with_block("0 0 * * * other", "proj.a", mine)
    assert_equal mine, CRON.with_block("", "proj.a", mine)
  end

  def test_with_block_does_not_confuse_ids_sharing_a_prefix
    text = CRON.block("proj.sync", ["a"]) + CRON.block("proj.sync-all", ["b"])
    assert_equal CRON.block("proj.sync-all", ["b"]), CRON.without_block(text, "proj.sync")
  end

  def test_parse_job_survives_a_project_directory_named_asgard
    command = CRON.command(arguments: %w[/bin/asgard sync], working_directory: "/src/asgard", environment: { "PATH" => "/bin" },
                           log_path: "/l")
    job = CRON.parse_job("0 1 * * * #{command}")
    assert_equal %w[/bin/asgard sync], job[:arguments]
    assert_equal "/src/asgard", job[:directory]
  end

  def test_install_writes_a_block_and_leaves_other_lines_alone
    crontab = FakeCrontab.new("MAILTO=me\n0 5 * * * backup\n")
    assert_equal :active, install(crontab, at: "17:30", on: :weekdays)
    assert_includes crontab.text, "MAILTO=me\n0 5 * * * backup\n# asgard:begin my-app.demo\n30 17 * * 1,2,3,4,5 cd /proj && "
    assert_includes crontab.text,
                    "/opt/bin/asgard demo >> #{@home}/.local/state/asgard/asgard.my-app.demo.log 2>&1\n# asgard:end my-app.demo\n"
  end

  def test_install_from_no_crontab
    crontab = FakeCrontab.new
    install(crontab, every: 300)
    assert_equal ["my-app.demo"], CRON.parse_blocks(crontab.text).keys
  end

  def test_install_twice_keeps_one_block
    crontab = FakeCrontab.new
    2.times { install(crontab, at: "17:30") }
    assert_equal 1, crontab.text.scan("asgard:begin").size
  end

  def test_install_refuses_an_unsayable_interval_before_touching_the_crontab
    crontab = FakeCrontab.new("0 5 * * * backup\n")
    assert_raises(Asgard::Schedule::Error) { install(crontab, every: 90) }
    assert_equal "0 5 * * * backup\n", crontab.text
  end

  def test_install_creates_the_log_directory
    Dir.mktmpdir do |home|
      backend(FakeCrontab.new, home:).install(spec(every: 60), asgard: "/a", direnv: nil)
      assert Dir.exist?(File.join(home, ".local/state/asgard"))
    end
  end

  def test_install_honors_xdg_state_home
    cron = CRON.new(project: "p", root: "/r", home: "/h", runner: FakeCrontab.new, env: { "XDG_STATE_HOME" => "/xdg" })
    assert_equal "/xdg/asgard/asgard.p.demo.log", cron.log_path("demo")
  end

  def test_files_shows_the_block_install_would_write
    shown = backend.files(spec(at: "02:00"), asgard: "/a", direnv: nil)
    assert_equal ["crontab"], shown.keys
    assert_includes shown["crontab"], "0 2 * * * cd /proj && "
  end

  def test_stop_comments_the_block_out_and_install_keeps_it_stopped
    crontab = FakeCrontab.new
    install(crontab, at: "17:30")
    backend(crontab).stop("demo")
    assert_equal :stopped, backend(crontab).status("demo")[:state]
    assert_match(/^#~ 30 17 \* \* \*/, crontab.text)

    assert_equal :stopped, install(crontab, at: "18:00")
    assert_match(/^#~ 0 18 \* \* \*/, crontab.text)

    backend(crontab).start("demo")
    assert_equal :active, backend(crontab).status("demo")[:state]
    assert_match(/^0 18 \* \* \*/, crontab.text)
  end

  def test_start_and_stop_of_an_unknown_entry_raise
    assert_raises(Asgard::Schedule::Error) { backend.stop("nope") }
    assert_raises(Asgard::Schedule::Error) { backend.start("nope") }
  end

  def test_uninstall_removes_only_its_block
    crontab = FakeCrontab.new("0 5 * * * backup\n")
    install(crontab, every: 60)
    backend(crontab).uninstall("demo")
    assert_equal "0 5 * * * backup\n", crontab.text
  end

  def test_uninstall_of_an_unknown_entry_does_not_write
    crontab = FakeCrontab.new("0 5 * * * backup\n")
    backend(crontab).uninstall("nope")
    assert_equal [["crontab", "-l"]], crontab.calls
  end

  def test_status
    crontab = FakeCrontab.new
    assert_equal({ state: :not_loaded, last_exit: "n/a" }, backend(crontab).status("demo"))
    install(crontab, every: 60)
    assert_equal({ state: :active, last_exit: "n/a" }, backend(crontab).status("demo"))
  end

  def test_installed_names_and_entries
    crontab = FakeCrontab.new
    install(crontab, as: "one", every: 60)
    install(crontab, as: "two.v2", every: 60)
    CRON.new(project: "Other", root: "/o", runner: crontab, env: {}).install(spec(every: 60), asgard: "/a", direnv: nil)

    assert_equal %w[one two.v2], backend(crontab).installed_names
    assert_equal [%w[my-app one], %w[my-app two.v2], %w[other demo]], backend(crontab).installed_entries
  end

  def test_installed_columns_round_trip
    ROUND_TRIPS.each do |settings|
      crontab = FakeCrontab.new
      install(crontab, **settings)
      assert_equal Asgard::Schedule.list_columns(spec(**settings)), backend(crontab).installed_columns("demo"), settings.inspect
    end
  end

  def test_installed_columns_drops_the_direnv_wrapper
    crontab = FakeCrontab.new
    backend(crontab).install(spec(at: "17:00"), asgard: "/opt/bin/asgard", direnv: "/opt/homebrew/bin/direnv")
    assert_equal "asgard demo", backend(crontab).installed_columns("demo")[:command]
  end

  def test_installed_directory_and_columns_are_nil_when_missing_or_emptied
    crontab = FakeCrontab.new
    install(crontab, at: "17:00")
    assert_equal "/proj", backend(crontab).installed_directory("demo")
    assert_nil backend(crontab).installed_directory("nope")
    assert_nil backend(crontab).installed_columns("nope")

    crontab.text = CRON.block("my-app.demo", [])
    assert_nil backend(crontab).installed_columns("demo")
  end

  # Runs the installed job for real: a stand-in asgard that records its arguments.
  def test_trigger_runs_the_installed_command_in_the_background
    crontab = FakeCrontab.new
    asgard  = File.join(@home, "asgard")
    File.write(asgard, "#!/bin/sh\necho \"ran in $(pwd) with: $*\"\n")
    File.chmod(0o755, asgard)
    cron = CRON.new(project: "p", root: @home, home: @home, runner: crontab, env: {})
    cron.install(spec(at: "17:00", options: "--title 'Week 100%'", as: "demo"), asgard:, direnv: nil)

    cron.trigger("demo")
    log = cron.log_path("demo")
    50.times { File.exist?(log) && !File.empty?(log) ? break : sleep(0.1) }
    assert_equal "ran in #{@home} with: demo --title Week 100%\n", File.read(log)
  end

  def test_trigger_of_an_unknown_entry_raises
    assert_raises(Asgard::Schedule::Error) { backend.trigger("nope") }
  end

  def test_a_failing_crontab_is_never_read_as_empty
    crontab = FakeCrontab.new(list_error: "crontab: you are not allowed to use this program\n")
    assert_raises(Asgard::Schedule::Error) { install(crontab, every: 60) }
    assert_equal [["crontab", "-l"]], crontab.calls
  end

  def test_a_failing_crontab_write_raises
    runner = FakeRunner.new("crontab -l" => ["", true], "crontab /" => ["bad crontab", false])
    assert_raises(Asgard::Schedule::Error) { CRON.new(project: "p", root: "/r", runner:, env: {}).install(spec(every: 60), asgard: "/a", direnv: nil) }
  end

  def test_notes_say_what_cron_cannot_do
    assert_match(/missed runs/, backend.notes.first)
  end

  def test_scheduler_name
    assert_equal "cron", backend.scheduler
  end

  def test_backend_class_can_be_chosen
    assert_equal CRON, Asgard::Schedule.backend_class("arm64-darwin25", scheduler: "cron")
    assert_equal CRON, Asgard::Schedule.backend_class("x86_64-freebsd", scheduler: "CRON")
    assert_equal Asgard::Schedule::Windows, Asgard::Schedule.backend_class("arm64-darwin25", scheduler: "windows")
    assert_equal Asgard::Schedule::Launchd, Asgard::Schedule.backend_class("x86_64-linux", scheduler: "launchd")
    assert_equal Asgard::Schedule::Launchd, Asgard::Schedule.backend_class("arm64-darwin25", scheduler: "")
    assert_raises(Asgard::Schedule::Error) { Asgard::Schedule.backend_class("x86_64-linux", scheduler: "at") }
  end
end

# Stands in for schtasks.exe: holds the registered tasks' XML, answers the
# queries the Windows backend makes, and records every argv like FakeRunner.
class FakeSchtasks
  attr_reader :calls, :tasks
  attr_accessor :last_result, :last_run

  def initialize
    @tasks       = {}
    @calls       = []
    @last_result = "0"
    @last_run    = "10/3/2026 5:30:00 PM"
  end

  def commands = @calls.map { |cmd| cmd.join(" ") }

  def call(*argv)
    @calls << argv
    return ["'#{argv.first}' is not recognized", false] unless argv.first == "schtasks"

    case argv.drop(1)
    in ["/Create", "/TN", name, "/XML", path, "/F"] then create(name, path)
    in ["/Delete", "/TN", name, "/F"]               then found(name) { @tasks.delete(name) }
    in ["/Change", "/TN", name, "/ENABLE"]          then found(name) { enable(name, true) }
    in ["/Change", "/TN", name, "/DISABLE"]         then found(name) { enable(name, false) }
    in ["/Run", "/TN", name]                        then found(name) { nil }
    in ["/Query", "/TN", name, "/XML"]              then found(name) { @tasks[name] }
    in ["/Query", "/TN", name, "/FO", "LIST", "/V"] then found(name) { listing(name) }
    in ["/Query", "/FO", "CSV", "/NH"]              then [@tasks.keys.map { |name| %("#{name}","N/A","Ready"\n) }.join, true]
    end
  end

  private

  def create(name, path)
    @tasks[name] = File.read(path.tr("\\", "/"))
    ["SUCCESS: The scheduled task \"#{name}\" has successfully been created.\n", true]
  end

  def found(name)
    return ["ERROR: The system cannot find the file specified.\n", false] unless @tasks.key?(name)

    [yield.to_s, true]
  end

  def enable(name, on)
    @tasks[name] = @tasks[name].sub(%r{<Enabled>(true|false)</Enabled>}, "<Enabled>#{on}</Enabled>")
    nil
  end

  def listing(name)
    "HostName:      PC\nTaskName:      #{name}\nStatus:        Ready\nLast Run Time: #{@last_run}\nLast Result:   #{@last_result}\n"
  end
end

class TestScheduleWindows < Minitest::Test
  WIN = Asgard::Schedule::Windows

  def spec(**) = Asgard::Schedule.normalize(:demo, **)

  def setup = @home = Dir.mktmpdir

  def teardown = FileUtils.rm_rf(@home)

  def backend(schtasks = FakeSchtasks.new, env: {}) = WIN.new(project: "My App", root: "/proj", home: @home, runner: schtasks, env:)

  def install(schtasks, **settings) = backend(schtasks).install(spec(**settings), asgard: "C:/Ruby/bin/asgard.bat", direnv: nil)

  ROUND_TRIPS = [
    { at: "13:30", on: :friday },
    { at: "17:00", on: :weekdays },
    { at: %w[10:00 11:00 12:00 13:00], on: :weekdays },
    { at: %w[09:00 18:30], on: %i[monday thursday] },
    { at: "06:15" },
    { every: 90 * 60 },
    { at: "08:00", options: "--period week --title 'Week End'", as: "demo" }
  ].freeze

  def test_task_name_slugs_the_project
    assert_equal "\\asgard\\my-app\\sync", WIN.task_name("My_App", :sync)
  end

  def test_quote
    assert_equal "plain", WIN.quote("plain")
    assert_equal %("two words"), WIN.quote("two words")
    assert_equal %("a&b"), WIN.quote("a&b")
    assert_equal %(""), WIN.quote("")
    assert_raises(Asgard::Schedule::Error) { WIN.quote(%(say "hi")) }
  end

  def test_command_line_sets_the_environment_and_appends_to_the_log
    line = WIN.command_line(arguments: ["C:\\Ruby\\bin\\asgard.bat", "report", "Week 39"],
                            environment: { "PATH" => "C:\\Ruby\\bin;C:\\Windows", "API_KEY" => "k" },
                            log_path: "C:/Users/me/AppData/Local/asgard/logs/x.log")
    assert_equal 'set "PATH=C:\Ruby\bin;C:\Windows" && set "API_KEY=k" && C:\Ruby\bin\asgard.bat report "Week 39" ' \
                 '>> "C:\Users\me\AppData\Local\asgard\logs\x.log" 2>&1', line.delete_prefix("/c ")
  end

  def test_parse_arguments_undoes_command_line
    arguments = ["C:\\a b\\asgard.bat", "report", "--title", "Week 39", "x&y"]
    line = WIN.command_line(arguments:, environment: { "PATH" => "C:\\x" }, log_path: "C:/l.log")
    assert_equal arguments, WIN.parse_arguments(line)
    assert_equal %w[asgard.bat demo], WIN.parse_arguments("/c asgard.bat demo >> log 2>&1")
    assert_equal %w[asgard.bat demo], WIN.parse_arguments("/c asgard.bat demo")
  end

  def test_calendar_trigger
    weekly = WIN.calendar_trigger({ hour: 17, minute: 30, days: [1, 5] })
    assert_includes weekly, "<StartBoundary>2000-01-01T17:30:00</StartBoundary>"
    assert_includes weekly, "<DaysOfWeek><Monday/><Friday/></DaysOfWeek>"
    assert_includes WIN.calendar_trigger({ hour: 2, minute: 0, days: nil }), "<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>"
  end

  def test_time_trigger
    assert_includes WIN.time_trigger(300), "<Interval>PT5M</Interval>"
    assert_includes WIN.time_trigger(31 * 86_400), "<Interval>PT44640M</Interval>"
    [30, 90, 32 * 86_400].each { |seconds| assert_raises(Asgard::Schedule::Error, seconds.to_s) { WIN.time_trigger(seconds) } }
  end

  def test_task_xml_is_escaped_and_complete
    xml = WIN.task_xml(description: "a <b> & c", arguments: ["C:\\asgard.bat", "say", "x&y"], working_directory: "/my proj",
                       environment: { "PATH" => "C:\\x" }, log_path: "/l/x.log", calendar: [{ hour: 1, minute: 2, days: nil }],
                       enabled: true)
    assert_includes xml, "<Description>a &lt;b&gt; &amp; c</Description>"
    assert_includes xml,
                    %(<Arguments>/c set "PATH=C:\\x" &amp;&amp; C:\\asgard.bat say "x&amp;y" &gt;&gt; "\\l\\x.log" 2&gt;&amp;1</Arguments>)
    assert_includes xml, "<WorkingDirectory>\\my proj</WorkingDirectory>"
    assert_includes xml, "<Enabled>true</Enabled>"
    assert_includes xml, "<StartWhenAvailable>true</StartWhenAvailable>"
    assert_includes xml, "<LogonType>InteractiveToken</LogonType>"
    assert_includes WIN.task_xml(description: "d", arguments: ["a"], working_directory: "/", environment: {}, log_path: "/l",
                                 every: 60, enabled: false), "<Enabled>false</Enabled>"
  end

  def test_parse_duration_accepts_normalized_forms
    assert_equal 5400, WIN.parse_duration("PT90M")
    assert_equal 5400, WIN.parse_duration("PT1H30M")
    assert_equal 86_400, WIN.parse_duration("PT24H")
    assert_equal 30, WIN.parse_duration("PT30S")
  end

  def test_parse_task_tolerates_task_scheduler_formatting
    xml = <<~XML
      <Triggers><CalendarTrigger>
        <StartBoundary>2000-01-01T17:30:00</StartBoundary>
        <ScheduleByWeek><DaysOfWeek><Monday /><Friday /></DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek>
      </CalendarTrigger></Triggers>
      <Settings><Enabled>false</Enabled></Settings>
      <Actions><Exec><Arguments>/c set "PATH=C:\\x" &amp;&amp; C:\\asgard.bat demo &gt;&gt; C:\\l.log 2&gt;&amp;1</Arguments>
      <WorkingDirectory>C:\\proj &amp; co</WorkingDirectory></Exec></Actions>
    XML
    parsed = WIN.parse_task(xml)
    assert_equal ["C:\\asgard.bat", "demo"], parsed[:arguments]
    assert_equal [{ hour: 17, minute: 30, days: [1, 5] }], parsed[:calendar]
    assert_nil parsed[:every]
    assert_equal "C:\\proj & co", WIN.parse_directory(xml)
    refute WIN.enabled?(xml)
    assert WIN.enabled?("<Triggers><Enabled>false</Enabled></Triggers><Settings><Enabled>true</Enabled></Settings>")
  end

  def test_parse_last_result
    assert_equal "0", WIN.parse_last_result("Last Run Time: 10/3/2026 5:30:00 PM\nLast Result:   0\n")
    assert_equal "1", WIN.parse_last_result("Last Run Time: 10/3/2026 5:30:00 PM\nLast Result:   1\n")
    assert_nil WIN.parse_last_result("Last Run Time: N/A\nLast Result:   1\n")
    assert_nil WIN.parse_last_result("Last Run Time: 11/30/1999 12:00:00 AM\nLast Result:   267011\n")
  end

  def test_parse_query_keeps_only_asgard_tasks
    csv = <<~CSV
      "\\asgard\\my-app\\demo","N/A","Ready"
      "\\Microsoft\\Windows\\Defrag\\ScheduledDefrag","N/A","Ready"
      "\\asgard\\other\\two.v2","N/A","Disabled"
      INFO: trailing noise
    CSV
    assert_equal [%w[my-app demo], %w[other two.v2]], WIN.parse_query(csv)
  end

  def test_install_writes_the_definition_and_registers_it
    schtasks = FakeSchtasks.new
    assert_equal :active, install(schtasks, at: "17:30", on: :weekdays)
    path = File.join(@home, "AppData/Local/asgard/tasks/asgard.my-app.demo.xml")
    assert File.exist?(path)
    assert Dir.exist?(File.join(@home, "AppData/Local/asgard/logs"))
    assert_equal ["schtasks", "/Create", "/TN", "\\asgard\\my-app\\demo", "/XML", path.tr("/", "\\"), "/F"], schtasks.calls.last
    assert_includes schtasks.tasks["\\asgard\\my-app\\demo"], "<Monday/><Tuesday/><Wednesday/><Thursday/><Friday/>"
  end

  def test_install_honors_localappdata
    cron = WIN.new(project: "p", root: "/r", home: "/h", runner: FakeSchtasks.new, env: { "LOCALAPPDATA" => "D:/data" })
    assert_equal "D:/data/asgard/logs/asgard.p.demo.log", cron.log_path("demo")
  end

  def test_install_refuses_an_unsayable_interval_before_registering
    schtasks = FakeSchtasks.new
    assert_raises(Asgard::Schedule::Error) { install(schtasks, every: 90) }
    assert_empty schtasks.tasks
  end

  def test_install_raises_on_schtasks_failure
    runner = FakeRunner.new("schtasks /Query" => ["ERROR: not found", false], "schtasks /Create" => ["ERROR: Access is denied.", false])
    assert_raises(Asgard::Schedule::Error) { backend(runner).install(spec(every: 60), asgard: "/a", direnv: nil) }
  end

  def test_files_shows_the_definition_install_would_write
    shown = backend.files(spec(at: "02:00"), asgard: "C:/asgard.bat", direnv: nil)
    assert_equal [File.join(@home, "AppData/Local/asgard/tasks/asgard.my-app.demo.xml")], shown.keys
    assert_includes shown.values.first, "<StartBoundary>2000-01-01T02:00:00</StartBoundary>"
  end

  def test_stop_disables_and_install_keeps_it_stopped
    schtasks = FakeSchtasks.new
    install(schtasks, at: "17:30")
    backend(schtasks).stop("demo")
    assert_includes schtasks.commands, "schtasks /Change /TN \\asgard\\my-app\\demo /DISABLE"
    assert_equal :stopped, backend(schtasks).status("demo")[:state]

    assert_equal :stopped, install(schtasks, at: "18:00")
    assert_includes schtasks.tasks["\\asgard\\my-app\\demo"], "<Enabled>false</Enabled>"
    assert_includes schtasks.tasks["\\asgard\\my-app\\demo"], "T18:00:00"

    backend(schtasks).start("demo")
    assert_equal :active, backend(schtasks).status("demo")[:state]
  end

  def test_start_stop_and_trigger_of_an_unknown_task_raise
    %i[start stop trigger].each { |action| assert_raises(Asgard::Schedule::Error, action.to_s) { backend.public_send(action, "nope") } }
  end

  def test_trigger_runs_the_task
    schtasks = FakeSchtasks.new
    install(schtasks, every: 60)
    backend(schtasks).trigger("demo")
    assert_equal ["schtasks", "/Run", "/TN", "\\asgard\\my-app\\demo"], schtasks.calls.last
  end

  def test_uninstall_deletes_the_task_and_its_definition
    schtasks = FakeSchtasks.new
    install(schtasks, every: 60)
    backend(schtasks).uninstall("demo")
    assert_empty schtasks.tasks
    refute File.exist?(File.join(@home, "AppData/Local/asgard/tasks/asgard.my-app.demo.xml"))
    backend(schtasks).uninstall("demo") # already gone: not an error
  end

  def test_status
    schtasks = FakeSchtasks.new
    assert_equal({ state: :not_loaded, last_exit: nil }, backend(schtasks).status("demo"))
    install(schtasks, every: 60)
    assert_equal({ state: :active, last_exit: "0" }, backend(schtasks).status("demo"))
    schtasks.last_run = "N/A"
    assert_equal({ state: :active, last_exit: nil }, backend(schtasks).status("demo"))
  end

  def test_installed_names_and_entries
    schtasks = FakeSchtasks.new
    install(schtasks, as: "one", every: 60)
    install(schtasks, as: "two.v2", every: 60)
    WIN.new(project: "Other", root: "/o", home: @home, runner: schtasks, env: {}).install(spec(every: 60), asgard: "/a", direnv: nil)

    assert_equal %w[one two.v2], backend(schtasks).installed_names
    assert_equal [%w[my-app one], %w[my-app two.v2], %w[other demo]], backend(schtasks).installed_entries
    assert_empty backend(FakeRunner.new("schtasks /Query" => ["ERROR", false])).installed_entries
  end

  def test_installed_columns_round_trip
    ROUND_TRIPS.each do |settings|
      schtasks = FakeSchtasks.new
      install(schtasks, **settings)
      assert_equal Asgard::Schedule.list_columns(spec(**settings)), backend(schtasks).installed_columns("demo"), settings.inspect
    end
  end

  def test_installed_columns_drops_the_direnv_wrapper
    schtasks = FakeSchtasks.new
    backend(schtasks).install(spec(at: "17:00"), asgard: "C:/asgard.bat", direnv: "C:/direnv.exe")
    assert_equal "asgard demo", backend(schtasks).installed_columns("demo")[:command]
  end

  def test_installed_directory_and_columns_are_nil_when_missing
    schtasks = FakeSchtasks.new
    install(schtasks, at: "17:00")
    assert_equal "\\proj", backend(schtasks).installed_directory("demo")
    assert_nil backend(schtasks).installed_directory("nope")
    assert_nil backend(schtasks).installed_columns("nope")
  end

  def test_scheduler_name_and_notes
    assert_equal "windows", backend.scheduler
    assert_empty backend.notes
  end
end
