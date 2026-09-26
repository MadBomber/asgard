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
    assert_equal Asgard::Schedule::Launchd, Asgard::Schedule.backend_class("arm64-darwin25")
    assert_equal Asgard::Schedule::Systemd, Asgard::Schedule.backend_class("x86_64-linux")
    assert_raises(Asgard::Schedule::Error) { Asgard::Schedule.backend_class("x64-mingw-ucrt") }
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
    out, = capture_io { Dir.chdir(@project) { Tasks.start(%w[schedule list]) } }
    assert_match "No scheduled tasks installed for proj", out
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
    assert_match(/^tree  asgard tree \(every 60s\)  \[.+\]  log: /, out)

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
