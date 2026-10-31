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
    # "Week 39" is one word with a capital and a space, so the slug can't spell it: hash suffix
    assert_match(/\Areport-format-md-title-week-39-v-\h{8}\z/, spec[:name])
  end

  def test_normalize_rejects_on_with_every
    error = assert_raises(ArgumentError) { SD.normalize(:sync, every: 60, on: :friday) }
    assert_match "on: only applies to at:", error.message
    assert_nil SD.normalize(:sync, every: 60)[:on]
    assert_equal :daily, SD.normalize(:sync, at: "01:00")[:on]
  end

  def test_entry_name_keeps_simple_option_names_readable
    assert_equal "report-format-md-v", SD.entry_name("report", %w[--format md -v])
    assert_equal "report-period-week", SD.entry_name("report", %w[--period week])
    assert_equal "sync-dry-run-3", SD.entry_name("sync", %w[--dry-run 3])
  end

  def test_entry_name_tells_option_spellings_apart
    spaced = SD.entry_name("report", %w[--period week])
    equals = SD.entry_name("report", %w[--period=week])
    assert_match(/\Areport-period-week-\h{8}\z/, equals)
    refute_equal spaced, equals
    refute_equal SD.entry_name("report", ["--title", "Week End"]), SD.entry_name("report", %w[--title week end])
    assert_equal equals, SD.entry_name("report", %w[--period=week]) # stable
  end

  def test_entry_name_caps_long_options_with_a_hash
    long  = SD.entry_name("report", Array.new(100) { |i| "--flag#{i}" })
    other = SD.entry_name("report", Array.new(101) { |i| "--flag#{i}" })
    assert_operator long.length, :<=, SD::NAME_MAX
    assert_match(/-\h{8}\z/, long)
    refute_equal long, other
  end

  def test_check_lengths_raises_a_schedule_error
    assert_nil SD.check_lengths!(["/a/#{'x' * 255}"])
    error = assert_raises(SD::Error) { SD.check_lengths!(["/a/#{'x' * 256}.plist"]) }
    assert_match "too long", error.message
  end

  def test_writing_turns_system_errors_into_schedule_errors
    Dir.mktmpdir do |dir|
      blocker = File.join(dir, "file")
      File.write(blocker, "")
      assert_equal(:ok, SD.writing { :ok })
      error = assert_raises(SD::Error) { SD.writing { File.write(File.join(blocker, "x"), "") } }
      assert_match "could not write", error.message
    end
  end

  def test_signal_exit
    assert_equal "signal 15 (Terminated)", SD.signal_exit("15", "Terminated")
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

# Phase 3 schedule regressions: declaration validation and read-back.
class TestRegressionScheduleDeclaration < Minitest::Test
  S = Asgard::Schedule

  def test_regression_s4_empty_at_or_on_is_rejected
    assert_raises(ArgumentError) { S.normalize(:t, at: "09:00", on: []) }
    assert_raises(ArgumentError) { S.normalize(:t, at: []) }
  end

  def test_regression_s5_weekends_reads_back_as_weekends
    assert_equal "09:00 weekends", S.describe_calendar(S.calendar(at: "09:00", on: :weekends))
    assert_equal :weekends, S.day_names([0, 6])
    assert_equal :weekdays, S.day_names([5, 1, 2, 3, 4])
  end

  def test_regression_s6_a_dashed_task_is_the_underscored_command
    spec = S.normalize(:'daily-summary', at: "09:00")
    assert_equal "daily_summary", spec[:task]
    error = assert_raises(ArgumentError) { S.normalize("db:migrate", at: "09:00") }
    assert_match(/subcommand/, error.message)
  end

  def test_regression_s7_control_characters_and_bad_env_names_are_rejected
    assert_raises(ArgumentError) { S.normalize(:t, at: "09:00", env: { "A" => "x\nExecStartPre=/bin/evil" }) }
    assert_raises(ArgumentError) { S.normalize(:t, at: "09:00", options: ["--x", "a\nb"]) }
    assert_raises(ArgumentError) { S.normalize(:t, at: "09:00", env: { "BAD-NAME" => "1" }) }
    assert_raises(ArgumentError) { S.normalize(:t, at: "09:00", env: { "1ST" => "1" }) }
    assert_equal({ "OK_1" => "tab\there" }, S.normalize(:t, at: "09:00", env: { OK_1: "tab\there" })[:env], "a tab is fine")
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

  # S3: reinstalling an unchanged entry must not bootout a run in progress.
  def test_regression_s3_an_unchanged_install_leaves_the_loaded_job_alone
    Dir.mktmpdir do |home|
      backend(home, FakeRunner.new("launchctl print gui" => ["", false])).install(spec(every: 60), asgard: "/bin/asgard", direnv: nil)
      running = FakeRunner.new("launchctl print gui" => ["state = running\n", true])
      assert_equal :active, backend(home, running).install(spec(every: 60), asgard: "/bin/asgard", direnv: nil)
      refute(running.commands.any? { |cmd| cmd.include?("bootout") }, running.commands.join("\n"))
      refute(running.commands.any? { |cmd| cmd.include?("bootstrap") })
    end
  end

  def test_regression_s3_a_changed_install_still_reloads
    Dir.mktmpdir do |home|
      backend(home, FakeRunner.new("launchctl print gui" => ["", false])).install(spec(every: 60), asgard: "/bin/asgard", direnv: nil)
      loaded = FakeRunner.new("launchctl print gui" => ["", false],
                              "launchctl print gui/501/com.madbomber.asgard.my-app.demo" => ["", true])
      def loaded.call(*argv)
        super.tap { @responses.delete("launchctl print gui/501/com.madbomber.asgard.my-app.demo") if argv[1] == "bootout" }
      end
      assert_equal :active, backend(home, loaded).install(spec(every: 120), asgard: "/bin/asgard", direnv: nil)
      assert(loaded.commands.any? { |cmd| cmd.include?("bootout") })
      assert(loaded.commands.any? { |cmd| cmd.include?("bootstrap") })
    end
  end

  # S10: a plist that fails plutil must not replace the good one on disk.
  def test_regression_s10_a_plist_that_fails_lint_never_replaces_the_installed_one
    Dir.mktmpdir do |home|
      b = backend(home, FakeRunner.new("launchctl print gui" => ["", false]))
      b.install(spec(every: 60), asgard: "/bin/asgard", direnv: nil)
      good = File.read(b.plist_path("demo"))
      failing = FakeRunner.new("launchctl print gui" => ["", false], "plutil" => ["bad plist", false])
      assert_raises(Asgard::Schedule::Error) { backend(home, failing).install(spec(every: 120), asgard: "/bin/asgard", direnv: nil) }
      assert_equal good, File.read(b.plist_path("demo"))
      assert_equal [File.basename(b.plist_path("demo"))], Dir.children(File.dirname(b.plist_path("demo"))), "no temp file left"
    end
  end

  # S8: job files carry env: values, so only their owner may read them.
  def test_regression_s8_the_plist_is_private
    Dir.mktmpdir do |home|
      b = backend(home, FakeRunner.new("launchctl print gui" => ["", false]))
      b.install(spec(every: 60), asgard: "/bin/asgard", direnv: nil)
      assert_equal 0o600, File.stat(b.plist_path("demo")).mode & 0o777
    end
  end

  # S11: a running job and a job a signal ended both show as such.
  def test_regression_s11_status_reads_running_and_signal_exits
    running = FakeRunner.new("launchctl print gui" => ["state = running\n\tlast exit code = 0\n", true])
    assert_equal({ state: :running, last_exit: "0" }, backend("/h", running).status("demo"))
    signalled = FakeRunner.new("launchctl print gui" => ["state = not running\n\tlast terminating signal = Terminated: 15\n", true])
    assert_equal({ state: :active, last_exit: "signal 15 (Terminated)" }, backend("/h", signalled).status("demo"))
  end

  def test_uninstall_keeps_the_plist_when_bootout_fails
    Dir.mktmpdir do |home|
      runner = FakeRunner.new("launchctl print gui"   => ["\tstate = running\n", true],
                              "launchctl bootout gui" => ["Boot-out failed: 5: Input/output error", false])
      b = backend(home, runner)
      FileUtils.mkdir_p(File.dirname(b.plist_path("demo")))
      File.write(b.plist_path("demo"), "")
      error = assert_raises(Asgard::Schedule::Error) { b.uninstall("demo") }
      assert_match "still loaded", error.message
      assert_match "Input/output error", error.message
      assert File.exist?(b.plist_path("demo"))
      refute(runner.commands.any? { |cmd| cmd.include?("enable") })
    end
  end

  def test_install_rejects_names_too_long_for_a_file
    Dir.mktmpdir do |home|
      long  = Asgard::Schedule.normalize(:demo, every: 60, as: "x" * 240)
      error = assert_raises(Asgard::Schedule::Error) { backend(home).install(long, asgard: "/a", direnv: nil) }
      assert_match "too long", error.message
      refute Dir.exist?(File.join(home, "Library"))
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

  # S1: Environment= does no $ expansion (systemd.exec(5)), so a $ must
  # reach it as is; ExecStart= still needs it doubled.
  def test_regression_s1_dollar_in_an_env_value_is_literal
    unit = Asgard::Schedule::Systemd.service_unit(
      description: "d", arguments: ["/bin/asgard", "pay$day"], working_directory: "/proj",
      environment: { "PW" => %(a$b%c"d\\e) }, log_path: "/log/x.log"
    )
    assert_includes unit, %(Environment="PW=a$b%%c\\"d\\\\e"\n)
    assert_includes unit, %(ExecStart="/bin/asgard" "pay$$day"\n)
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

  def test_regression_s8_unit_files_are_private
    Dir.mktmpdir do |home|
      b = backend(home)
      b.install(spec(every: 60), asgard: "/bin/asgard", direnv: nil)
      [b.service_path("demo"), b.timer_path("demo")].each { |path| assert_equal 0o600, File.stat(path).mode & 0o777, path }
    end
  end

  # S9: a first install that fails part way must not look, next time,
  # like a timer the user stopped on purpose.
  def test_regression_s9_a_failed_first_install_is_not_taken_for_a_stop
    Dir.mktmpdir do |home|
      failing = FakeRunner.new("systemctl --user is-enabled" => ["disabled", false], "systemctl --user enable" => ["boom", false])
      assert_raises(Asgard::Schedule::Error) { backend(home, failing).install(spec(every: 60), asgard: "/bin/asgard", direnv: nil) }
      refute File.exist?(backend(home).timer_path("demo")), "the half-written first install is rolled back"
      fresh = FakeRunner.new("systemctl --user is-enabled" => ["disabled", false])
      assert_equal :active, backend(home, fresh).install(spec(every: 60), asgard: "/bin/asgard", direnv: nil)
    end
  end

  def test_service_unit_lets_background_jobs_outlive_the_run
    unit = Asgard::Schedule::Systemd.service_unit(description: "d", arguments: ["/a"], working_directory: "/",
                                                  environment: {}, log_path: "/l")
    assert_includes unit, "Type=oneshot\nKillMode=process\n"
  end

  def test_install_leaves_unchanged_units_alone
    Dir.mktmpdir do |home|
      backend(home).install(spec(every: 60), asgard: "/a", direnv: nil)
      runner = FakeRunner.new
      assert_equal :active, backend(home, runner).install(spec(every: 60), asgard: "/a", direnv: nil)
      assert_equal ["systemctl --user is-enabled --quiet asgard.my-app.demo.timer",
                    "systemctl --user enable asgard.my-app.demo.timer",
                    "systemctl --user start asgard.my-app.demo.timer"], runner.commands
    end
  end

  def test_install_reloads_and_restarts_changed_units
    Dir.mktmpdir do |home|
      backend(home).install(spec(every: 60), asgard: "/a", direnv: nil)
      runner = FakeRunner.new
      backend(home, runner).install(spec(every: 120), asgard: "/a", direnv: nil)
      assert_includes runner.commands, "systemctl --user daemon-reload"
      assert_includes runner.commands, "systemctl --user restart asgard.my-app.demo.timer"
    end
  end

  def test_install_rejects_names_too_long_for_a_file
    Dir.mktmpdir do |home|
      long  = Asgard::Schedule.normalize(:demo, every: 60, as: "x" * 240)
      error = assert_raises(Asgard::Schedule::Error) { backend(home).install(long, asgard: "/a", direnv: nil) }
      assert_match "too long", error.message
    end
  end

  def test_uninstall_keeps_units_when_disable_fails
    Dir.mktmpdir do |home|
      backend(home).install(spec(every: 60), asgard: "/a", direnv: nil)
      runner = FakeRunner.new("systemctl --user disable" => ["Failed to connect to bus", false])
      b = backend(home, runner)
      error = assert_raises(Asgard::Schedule::Error) { b.uninstall("demo") }
      assert_match "Failed to connect to bus", error.message
      assert_equal ["demo"], b.installed_names
    end
  end

  def test_status_reports_running_and_signal_exits
    running = FakeRunner.new("systemctl --user show" => ["ActiveState=activating\nSubState=start\nExecMainCode=0\n" \
                                                         "ExecMainStatus=0\nExecMainExitTimestampMonotonic=0\n", true])
    assert_equal({ state: :running, last_exit: nil }, backend("/h", running).status("demo"))

    killed = FakeRunner.new("systemctl --user show" => ["ActiveState=inactive\nSubState=dead\nExecMainCode=2\n" \
                                                        "ExecMainStatus=15\nExecMainExitTimestampMonotonic=99\n", true])
    assert_equal({ state: :active, last_exit: "signal 15 (SIGTERM)" }, backend("/h", killed).status("demo"))
  end

  def test_notes_mention_linger_only_when_off
    off = FakeRunner.new("loginctl" => ["no\n", true])
    assert_match(/enable-linger/, backend("/h", off).notes.first)
    on = FakeRunner.new("loginctl" => ["yes\n", true])
    assert_empty backend("/h", on).notes
  end
end

class TestScheduleRegistry < Minitest::Test
  SD = Asgard::Schedule

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

  # Different commands whose plain names slug alike both take hashed
  # names, whatever order they are declared in.
  def test_rival_commands_both_take_hashed_names
    rivals = [[:report, "--period week"], [:report, "period week"], [:report_period, "week"]]
    expected = rivals.map { |task, options| SD.hashed_slug(task.to_s, Shellwords.split(options)) }

    [rivals, rivals.reverse, rivals.rotate].each do |order|
      SD.declarations.clear
      order.each { |task, options| Tasks.schedule task, options:, every: 60 }
      assert_equal expected.sort, SD.declarations.keys.sort, order.inspect
      SD.declarations.each { |name, spec| assert_equal name, spec[:name] }
    end
    refute_includes SD.declarations.keys, "report-period-week"
  end

  def test_a_rival_declared_twice_is_still_one_entry
    2.times do
      Tasks.schedule :report, options: "--period week", every: 60
      Tasks.schedule :report, options: "period week", every: 60
    end
    assert_equal 2, SD.declarations.size
  end

  def test_the_same_command_with_another_schedule_still_raises
    Tasks.schedule :report, options: "--period week", every: 60
    Tasks.schedule :report, options: "period week", every: 60
    assert_raises(ArgumentError) { Tasks.schedule :report, options: "period week", every: 120 }
  end

  def test_an_unrivalled_command_keeps_its_plain_name
    Tasks.schedule :report, options: "--period week", every: 60
    Tasks.schedule :report, options: "--period month", every: 60
    assert_equal %w[report-period-month report-period-week], SD.declarations.keys.sort
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
    @slug    = Asgard::Schedule.project_slug(@project)
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

  def backend = Asgard::Schedule.backend_class.new(project: @slug, root: File.realpath(@project))

  def test_asgard_schedule_maps_to_the_subcommand
    Asgard::Schedule::Commands._reset_ran! # each task runs once per process; an earlier test may have run `list`
    out, = capture_io { Dir.chdir(@project) { Tasks.start(%w[schedule list]) } }
    assert_match "No scheduled tasks installed for #{@slug}", out
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
    assert_equal ["Project: elsewhere (#{@tmp})", "Project: #{@slug} (#{File.realpath(@project)})"],
                 out.lines.grep(/^Project:/).map(&:chomp)
    assert_match(/^Project: elsewhere .*\n┌.*?│ nightly\s+│ asgard tree\s+│ every 60s/m, out)
    assert_match(/^Project: #{@slug} .*\n┌.*?│ tree\s+│ asgard tree/m, out)
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
    assert disabled?("asgard.#{@slug}.tree")
    refute disabled?("asgard.elsewhere.tree")
    assert_match "stopped elsewhere/tree", capture_io { schedule("stop", "elsewhere/tree") }.first
    assert disabled?("asgard.elsewhere.tree")
  end

  def test_the_project_basename_alone_names_this_project_in_a_prefixed_argument
    install_elsewhere(also_here: true)
    Asgard::Schedule.declarations.clear

    assert_match "stopped proj/tree", capture_io { schedule("stop", "proj/tree") }.first
    assert disabled?("asgard.#{@slug}.tree")
    refute disabled?("asgard.elsewhere.tree")
  end

  # S2: entries of a project that moved or was deleted keep firing; they
  # must be removable by project/name, and prune removes them all.
  def install_gone(name = :tree)
    gone = File.join(@tmp, "gone")
    Asgard::Schedule.backend_class.new(project: "gone", root: gone)
                    .install(Asgard::Schedule.normalize(name, every: 60), asgard: File.join(@bin, "asgard"), direnv: nil)
    Asgard::Schedule.backend_class.new(project: "gone", root: gone)
  end

  def test_regression_s2_remove_takes_another_projects_entry
    gone = install_gone
    out, = capture_io { schedule("remove", "gone/tree") }
    assert_match "removed gone/tree", out
    assert_empty gone.installed_names
  end

  def test_regression_s2_prune_removes_only_entries_whose_root_is_gone
    gone = install_gone
    install_elsewhere # its root, @tmp, exists
    out, = capture_io { schedule("prune", "--dry-run") }
    assert_match "would remove gone/tree", out
    assert_equal ["tree"], gone.installed_names, "a dry run removes nothing"
    out, = capture_io { schedule("prune") }
    assert_match "removed gone/tree", out
    refute_match "elsewhere", out
    assert_empty gone.installed_names
    assert_equal ["tree"], Asgard::Schedule.backend_class.new(project: "elsewhere", root: @tmp).installed_names
    out, = capture_io { schedule("prune") }
    assert_match "Nothing to prune", out
  end

  def test_regression_s2_orphaned_entries_is_pure
    entries = [%w[a x], %w[b y], %w[c z]]
    dirs    = { %w[a x] => "/exists", %w[b y] => "/gone", %w[c z] => nil }
    assert_equal [%w[b y]], Asgard::Schedule.orphaned_entries(entries, directory_of: ->(slug, name) { dirs[[slug, name]] },
                                                                          exists: ->(dir) { dir == "/exists" })
  end

  def test_list_all_flags_a_project_whose_directory_is_gone
    spec = Asgard::Schedule.normalize(:tree, every: 60)
    gone = File.join(@tmp, "gone")
    Asgard::Schedule.backend_class.new(project: "gone", root: gone).install(spec, asgard: File.join(@bin, "asgard"), direnv: nil)
    out, = capture_io { schedule("list", "--all") }
    assert_match "Project: gone (#{gone}) [root missing]", out
    refute_match "#{@slug} (#{File.realpath(@project)}) [root missing]", out
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
    assert_match "No scheduled tasks installed for #{@slug}.", out
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

  def test_table_draws_a_one_row_table_at_its_natural_widths
    headers = %w[JOB TASK PID STATUS STARTED COMMAND]
    keys    = %i[name task pid state started command]
    row     = { name: "jtdb", task: "jobs_test_db", pid: 63_962, state: "running", started: "2026-10-24 15:55:48", command: "sleep 30" }
    table   = SD::Table.new([row], color: false, width: 120, headers:, keys:, flexible: [5])
    out     = table.render
    assert_equal [6, 14, 7, 9, 21, 10], table.column_widths, "content plus a space either side"
    assert_equal 5, out.lines.size, "nothing wraps: top, header, rule, one row, bottom"
    assert_match(/│ jtdb │ jobs_test_db │ 63962 │ running │ 2026-10-24 15:55:48 │ sleep 30 │/, out)
  end

  def test_table_colors_only_on_request
    rows = [{ name: "a", command: "c", schedule: "s", state: "active", last_exit: "1" }]
    assert_includes SD::Table.new(rows, color: true, width: 100).render, "\e[31m1"
    killed = [{ **rows.first, last_exit: "signal 15 (Terminated)" }]
    assert_includes SD::Table.new(killed, color: true, width: 100).render, "\e[31msignal"
  end

  def test_terminal_width_for_non_tty_uses_columns_then_default
    io = StringIO.new
    assert_equal 120, SD::Table.terminal_width(io, env: {})
    assert_equal 90,  SD::Table.terminal_width(io, env: { "COLUMNS" => "90" })
    assert_equal 120, SD::Table.terminal_width(io, env: { "COLUMNS" => "wide" })
  end
end

# Project slugs: the basename plus a hash of the real path, and the matching
# that lets a `project/name` argument name a project by basename alone.
class TestScheduleProjectSlug < Minitest::Test
  def test_project_slug_is_the_basename_plus_a_hash_of_the_real_path
    Dir.mktmpdir do |dir|
      real = File.realpath(dir)
      slug = Asgard::Schedule.project_slug(dir)
      assert_match(/\A#{Regexp.escape(File.basename(real).downcase)}-\h{8}\z/, slug)
      assert_equal slug, Asgard::Schedule.project_slug(real), "the same path, however spelled, gives one slug"
      Dir.mktmpdir do |other|
        link = File.join(other, "link")
        File.symlink(real, link)
        assert_equal slug, Asgard::Schedule.project_slug(link), "a symlink to the project gives the project's slug"
      end
    end
  end

  def test_same_basename_in_two_directories_gives_two_slugs
    Dir.mktmpdir do |a|
      Dir.mktmpdir do |b|
        FileUtils.mkdir_p [File.join(a, "api"), File.join(b, "api")]
        refute_equal Asgard::Schedule.project_slug(File.join(a, "api")), Asgard::Schedule.project_slug(File.join(b, "api"))
      end
    end
  end

  def test_project_match_takes_the_whole_slug_or_the_basename
    assert Asgard::Schedule.project_match?("api-9f3a1c2b", "api-9f3a1c2b")
    assert Asgard::Schedule.project_match?("api-9f3a1c2b", "api")
    refute Asgard::Schedule.project_match?("api-9f3a1c2b", "ap")
    refute Asgard::Schedule.project_match?("api-9f3a1c2b", "api-9f3a1c2c")
    assert Asgard::Schedule.project_match?("elsewhere", "elsewhere"), "an entry from before the hash still matches by its slug"
  end
end

# The helpers schedule and watch share, and the backends' job-file reading.
class TestSharedDeclarationHelpers < Minitest::Test
  def test_record_stores_an_entry_and_ignores_an_identical_one
    declarations = {}
    spec = { name: "lint", task: "lint" }
    assert_equal spec, Asgard::Declarations.record(declarations, spec, "watch")
    Asgard::Declarations.record(declarations, spec.dup, "watch")
    assert_equal({ "lint" => spec }, declarations)
  end

  def test_record_refuses_a_different_entry_under_the_same_name
    declarations = { "lint" => { name: "lint", every: 60 } }
    error = assert_raises(ArgumentError) { Asgard::Declarations.record(declarations, { name: "lint", every: 120 }, "schedule") }
    assert_equal 'schedule: "lint" is already declared; give one a distinct as: name', error.message
  end

  def test_job_file_entries_split_project_and_name
    paths = %w[/a/asgard.api-9f3a1c2b.report.timer /a/asgard.web-1a2b3c4d.sync.timer /a/asgard.loose.timer]
    assert_equal [%w[api-9f3a1c2b report], %w[web-1a2b3c4d sync]],
                 Asgard::Schedule::JobFiles.entries(paths, prefix: "asgard", ext: ".timer")
  end

  def test_job_file_entries_in_globs_the_directory
    Dir.mktmpdir do |dir|
      %w[asgard.p.one.timer asgard.p.two.timer asgard.p.one.service other.timer].each { FileUtils.touch(File.join(dir, it)) }
      assert_equal [%w[p one], %w[p two]], Asgard::Schedule::JobFiles.entries_in(dir, prefix: "asgard", ext: ".timer")
    end
  end

  def test_job_file_directory_reads_with_the_parser_or_is_nil
    Dir.mktmpdir do |dir|
      path = File.join(dir, "job")
      parser = ->(text) { text[/^WorkingDirectory=(.*)$/, 1] }
      assert_nil Asgard::Schedule::JobFiles.directory(path, parser)
      File.write(path, "WorkingDirectory=/proj\n")
      assert_equal "/proj", Asgard::Schedule::JobFiles.directory(path, parser)
    end
  end
end
