# frozen_string_literal: true

require_relative "test_helper"

class TestLog < Minitest::Test
  Log = Asgard::Log

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "task.log")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_retains_exact_bytes_including_partial_lines_and_binary_output
    ["one\ntwo\nthree\n", "one\ntwo\nthree", "one\r\ntwo\r\nthree\r\n", "one\n\xFFtwo\nthree\n".b].each do |body|
      File.binwrite(@path, body)
      inode = File.stat(@path).ino
      kept = body.lines.last(2).join
      assert_equal body.bytesize - kept.bytesize, Log.truncate(@path, lines: 2)
      assert_equal kept, File.binread(@path)
      assert_equal inode, File.stat(@path).ino
    end
  end

  def test_zero_empties_and_short_logs_are_unchanged
    ["", "one", "one\n", "\n\n"].each do |body|
      File.binwrite(@path, body)
      assert_equal 0, Log.truncate(@path, lines: 3)
      assert_equal body, File.binread(@path)
      assert_equal body.bytesize, Log.truncate(@path, lines: 0)
      assert_empty File.binread(@path)
    end
  end

  def test_tail_crosses_chunk_boundaries_and_retains_long_lines
    body = "old\n#{"x" * (Log::CHUNK + 5)}\nlast\n"
    File.binwrite(@path, body)
    assert_equal 4, Log.truncate(@path, lines: 2)
    assert_equal body.delete_prefix("old\n"), File.binread(@path)
    assert_equal Log::CHUNK + 6, Log.truncate(@path, lines: 1)
    assert_equal "last\n", File.binread(@path)
  end

  def test_dry_run_changes_neither_the_log_nor_the_directory
    File.write(@path, "one\ntwo\n")
    before = File.stat(@path)
    files = Dir.children(@dir)
    assert_equal 4, Log.truncate(@path, lines: 1, dry_run: true)
    assert_equal "one\ntwo\n", File.read(@path)
    assert_equal files, Dir.children(@dir)
    assert_equal before.mtime, File.mtime(@path)
  end

  def test_invalid_line_counts
    [nil, "", "-1", "1.5", "NaN", "1e2", " 1", "0x10"].each do |value|
      assert_raises(ArgumentError) { Log.line_count(value) }
    end
    assert_equal 0, Log.line_count("0")
    assert_equal 15, Log.line_count("15")
  end

  def test_an_append_mode_writer_keeps_logging_to_the_same_file
    ready = File.join(@dir, "ready")
    go = File.join(@dir, "go")
    script = <<~RUBY
      $stdout.sync = true
      puts "old"
      puts "keep"
      File.write(ARGV[0], "")
      sleep 0.01 until File.exist?(ARGV[1])
      puts "after"
    RUBY
    pid = Process.spawn(Gem.ruby, "-e", script, ready, go, in: File::NULL, out: [@path, "a"])
    wait_until { File.exist?(ready) }
    assert_equal 4, Log.truncate(@path, lines: 1)
    File.write(go, "")
    Process.wait(pid)
    pid = nil
    assert_equal "keep\nafter\n", File.read(@path)
  ensure
    if pid
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until yield
      raise "timed out waiting for log writer" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end

class TestTruncateLogCommands < Minitest::Test
  include AsgardProcess

  def setup
    @dir = Dir.mktmpdir
    @root = File.join(@dir, "project")
    FileUtils.mkdir_p(@root)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def command(klass, lines: "1", dry_run: false)
    klass.new([], { lines:, dry_run: }, {})
  end

  def test_job_selection_includes_orphan_logs_but_not_other_projects_or_records
    state = Asgard::Jobs::State.new(project: "own", root: @root, base: @dir).prepare
    other = Asgard::Jobs::State.new(project: "other", root: @root, base: @dir).prepare
    paths = [state.log_path("one"), state.log_path("two"), other.log_path("one")]
    paths.each { |path| File.write(path, "old\nkeep\n") }
    File.write(state.record_path("one"), "{}")
    cli = command(Asgard::Jobs::Commands)
    cli.instance_variable_set(:@state, state)
    capture_io { cli.truncate_log("one") }
    assert_equal "keep\n", File.read(paths[0])
    assert_equal "old\nkeep\n", File.read(paths[1])
    capture_io { cli.truncate_log }
    assert_equal "keep\n", File.read(paths[1])
    assert_equal "old\nkeep\n", File.read(paths[2])
    assert_equal "{}", File.read(state.record_path("one"))
    capture_io { assert_raises(SystemExit) { cli.truncate_log("../other/one") } }
  end

  def test_watcher_processes_current_and_rotated_log_independently
    state = Asgard::Watch::State.new(project: "own", root: @root, base: @dir).prepare
    paths = [state.log_path, "#{state.log_path}.1"]
    paths.each { |path| File.write(path, "old\nkeep\n") }
    cli = command(Asgard::Watch::Commands)
    cli.instance_variable_set(:@state, state)
    capture_io { cli.truncate_log }
    paths.each { |path| assert_equal "keep\n", File.read(path) }
  end

  def test_schedule_selection_on_both_backends_includes_uninstalled_logs
    [Asgard::Schedule::Launchd, Asgard::Schedule::Systemd].each do |klass|
      backend = klass.new(project: "own", root: @root, home: @dir)
      other = klass.new(project: "other", root: @root, home: @dir)
      paths = [backend.log_path("one"), backend.log_path("two"), other.log_path("one")]
      FileUtils.mkdir_p(File.dirname(paths.first))
      paths.each { |path| File.write(path, "old\nkeep\n") }
      cli = command(Asgard::Schedule::Commands)
      cli.instance_variable_set(:@scheduler, backend)
      capture_io { cli.truncate_log("one") }
      assert_equal "keep\n", File.read(paths[0])
      assert_equal "old\nkeep\n", File.read(paths[1])
      capture_io { cli.truncate_log }
      assert_equal "keep\n", File.read(paths[1])
      assert_equal "old\nkeep\n", File.read(paths[2])
      capture_io { assert_raises(SystemExit) { cli.truncate_log("../other/one") } }
    end
  end

  def test_cli_validates_lines_and_exposes_the_command_in_all_help_groups
    %w[schedule watcher jobs].each do |group|
      %w[-1 1.5 nonsense].each do |lines|
        _, err, status = run_asgard("class Tasks; end", group, "truncate_log", "--lines=#{lines}")
        refute status.success?, "#{group}: #{lines}"
        assert_includes err, "--lines must be a nonnegative integer"
      end
      out, _, status = run_asgard("class Tasks; end", group, "help", "truncate_log")
      assert status.success?
      assert_includes out, "#{group} truncate_log"
      assert_includes out, "--lines"
      assert_includes out, "--dry-run"
      _, _, status = run_asgard("class Tasks; end", group, "truncate_log")
      refute status.success?, "#{group} must require --lines"
    end
  end

  def test_job_dry_run_reports_bytes_without_changing_files
    state = Asgard::Jobs::State.new(project: "own", root: @root, base: @dir).prepare
    File.write(state.log_path("one"), "old\nkeep\n")
    cli = command(Asgard::Jobs::Commands, dry_run: true)
    cli.instance_variable_set(:@state, state)
    before = Dir.children(state.dir)
    out, = capture_io { cli.truncate_log }
    assert_includes out, "4 bytes would be removed"
    assert_equal "old\nkeep\n", File.read(state.log_path("one"))
    assert_equal before, Dir.children(state.dir)
  end

  def test_no_logs_does_not_create_state
    cli = command(Asgard::Jobs::Commands)
    state = Asgard::Jobs::State.new(project: "absent", root: @root, base: @dir)
    cli.instance_variable_set(:@state, state)
    out, = capture_io { cli.truncate_log }
    assert_includes out, "No logs found"
    refute File.exist?(state.dir)
  end
end
