# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "ractor_queue"
require "stringio"
require "timeout"
require "json"

class TestWatchDeclaration < Minitest::Test
  W = Asgard::Watch

  # Stand-ins for File in split_glob: every plain path is / is not a file.
  IS_FILE  = Module.new do
    def self.file?(_path) = true
    def self.directory?(_path) = false
  end
  NOT_FILE = Module.new do
    def self.file?(_path) = false
    def self.directory?(_path) = false
  end

  def test_split_glob_directory
    assert_equal ["docs", nil], W.split_glob("docs", stat: NOT_FILE)
    assert_equal [".", nil],    W.split_glob(".", stat: NOT_FILE)
    assert_equal ["lib", nil],  W.split_glob("lib/", stat: NOT_FILE)
  end

  def test_split_glob_file_by_extension_or_stat
    dir, regexp = W.split_glob("lib/asgard.rb", stat: NOT_FILE)
    assert_equal "lib", dir
    assert_match regexp, "asgard.rb"
    refute_match regexp, "other.rb"
    assert_equal [".", /\AGemfile\z/], W.split_glob("Gemfile", stat: IS_FILE)
    assert_equal ["Gemfile", nil],     W.split_glob("Gemfile", stat: NOT_FILE)
  end

  def test_split_glob_asks_the_filesystem_for_plain_paths
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        File.write("Gemfile", "")
        assert_equal [".", /\AGemfile\z/], W.split_glob("Gemfile")
        assert_equal ["lib", nil],         W.split_glob("lib")
      end
    end
  end

  # W8: a plain path is a file or a directory in the project root, not in
  # whatever directory asgard runs from, and a dotted directory is a
  # directory.
  def test_regression_w8_plain_paths_are_judged_in_the_project_root
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "Gemfile"), "")
      FileUtils.mkdir_p [File.join(tmp, "sub"), File.join(tmp, "config.d")]
      Dir.chdir(File.join(tmp, "sub")) do
        assert_equal [".", /\AGemfile\z/], W.split_glob("Gemfile", root: tmp)
        assert_equal ["config.d", nil],    W.split_glob("config.d", root: tmp)
      end
    end
  end

  # W9: globs inside braces are globs too.
  def test_regression_w9_brace_alternatives_are_globs
    regexp = W.glob_regexp("{*.rb,*.rake}")
    %w[foo.rb x.rake].each { |path| assert_match regexp, path }
    refute_match regexp, "foo.py"
    refute_match regexp, "a/b.rb"
    assert_match W.glob_regexp("lib/{a,b?}/*.rb"), "lib/bc/x.rb"
  end

  def test_split_glob_patterns
    dir, regexp = W.split_glob("lib/**/*.rb")
    assert_equal "lib", dir
    %w[a.rb asgard/base.rb asgard/watch/x.rb].each { |path| assert_match regexp, path }
    %w[a.rbx asgard/base.md x.rb/y].each { |path| refute_match regexp, path }
    assert_equal ".",          W.split_glob("*.rb").first
    assert_equal "lib/asgard", W.split_glob("lib/asgard/*.rb").first
  end

  def test_glob_regexp_tokens
    assert_match W.glob_regexp("?.rb"), "a.rb"
    refute_match W.glob_regexp("?.rb"), "ab.rb"
    assert_match W.glob_regexp("*.{rb,md}"), "x.md"
    refute_match W.glob_regexp("*.{rb,md}"), "x.txt"
    refute_match W.glob_regexp("*.rb"), "a/b.rb"
    assert_match W.glob_regexp("**"), "a/b/c"
    assert_match W.glob_regexp("a.b"), "a.b"
    refute_match W.glob_regexp("a.b"), "axb"
    assert_match W.glob_regexp("{x"), "{x"
  end

  def test_combine_only
    assert_nil W.combine_only([], [])
    assert_equal(/\.rb\z/, W.combine_only([], [/\.rb\z/]))
    assert_equal(/\Aa\z/,  W.combine_only([/\Aa\z/], []))

    either = W.combine_only([/\Aa\z/, /\Ab\z/], [])
    assert_match either, "a"
    assert_match either, "b"
    refute_match either, "c"

    both = W.combine_only([W.glob_regexp("**/*")], [/\.rb\z/, /\.erb\z/])
    assert_match both, "a/b.rb"
    assert_match both, "a/b.erb"
    refute_match both, "a/b.md"
  end

  def test_normalize_events
    assert_equal Set[:changed, :added, :removed], W.normalize_events(:all)
    assert_equal Set[:changed],         W.normalize_events(:modified)
    assert_equal Set[:changed],         W.normalize_events("changed")
    assert_equal Set[:added, :removed], W.normalize_events(%i[added removed])
    assert_predicate W.normalize_events(:all), :frozen?
    assert_raises(ArgumentError) { W.normalize_events(:bogus) }
    assert_raises(ArgumentError) { W.normalize_events([]) }
    assert_raises(ArgumentError) { W.normalize_events(%i[all bogus]) }
  end

  def test_normalize_defaults
    spec = W.normalize(:lint, paths: "lib/**/*.rb")
    assert_equal "lint",          spec[:name]
    assert_equal "lint",          spec[:task]
    assert_equal ["lib/**/*.rb"], spec[:paths]
    assert_equal ["lib"],         spec[:dirs]
    assert_match spec[:only]["lib"], "asgard/base.rb"
    refute_match spec[:only]["lib"], "asgard/base.md"
    assert_equal Set[:changed, :added, :removed], spec[:events]
    assert_in_delta 0.5, spec[:debounce]
    assert_empty spec[:env]
    assert_equal({ "lib" => W::DEFAULT_IGNORES }, spec[:ignore])
  end

  def test_normalize_directories_with_only_ignore_env_and_as
    spec = W.normalize(:test, paths: %w[lib test], only: /\.rb\z/, ignore: %r{\Afixtures/}, env: { BUILD: :dev }, as: "unit")
    assert_equal "unit",       spec[:name]
    assert_equal "test",       spec[:task]
    assert_equal %w[lib test], spec[:dirs]
    assert_equal({ "lib" => /\.rb\z/, "test" => /\.rb\z/ }, spec[:only])
    assert_equal [%r{\Afixtures/}, *W::DEFAULT_IGNORES], spec[:ignore]["test"]
    assert_equal({ "BUILD" => "dev" }, spec[:env])
    assert_nil W.normalize(:t, paths: "lib")[:only]["lib"]
  end

  def test_normalize_dedups_dirs_and_accepts_any_pattern
    spec = W.normalize(:t, paths: %w[lib/**/*.rb lib/**/*.erb])
    assert_equal ["lib"], spec[:dirs]
    assert_match spec[:only]["lib"], "a/b.rb"
    assert_match spec[:only]["lib"], "a/b.erb"
    refute_match spec[:only]["lib"], "a/b.md"
  end

  def test_normalize_requires_both_pattern_and_only_when_both_given
    spec = W.normalize(:t, paths: "lib/**/*", only: /\.rb\z/)
    assert_match spec[:only]["lib"], "a/b.rb"
    refute_match spec[:only]["lib"], "a/b.md"
  end

  def test_normalize_rejects_mixing_directories_with_patterns
    error = assert_raises(ArgumentError) { W.normalize(:t, paths: %w[lib/**/*.rb docs]) }
    assert_includes error.message, "dir/**/*"
    assert_match(/\Awatch :t /, error.message)
    assert_raises(ArgumentError) { W.normalize(:t, paths: %w[Gemfile.lock docs]) }
  end

  def test_normalize_rejects_bad_input
    assert_raises(ArgumentError) { W.normalize("lint --fix", paths: "lib") }
    assert_raises(ArgumentError) { W.normalize(:t, paths: []) }
    assert_raises(ArgumentError) { W.normalize(:t, paths: "/abs") }
    assert_raises(ArgumentError) { W.normalize(:t, paths: "") }
    assert_raises(ArgumentError) { W.normalize(:t, paths: "lib", only: "rb") }
    assert_raises(ArgumentError) { W.normalize(:t, paths: "lib", ignore: [/ok/, "x"]) }
    assert_raises(ArgumentError) { W.normalize(:t, paths: "lib", events: :never) }
    assert_raises(ArgumentError) { W.normalize(:t, paths: "lib", debounce: -1) }
    assert_raises(ArgumentError) { W.normalize(:t, paths: "lib", debounce: "1") }
    assert_raises(ArgumentError) { W.normalize(:t, paths: "lib", as: "bad name") }
    error = assert_raises(ArgumentError) { W.normalize("lint --fix", paths: "lib") }
    assert_includes error.message, "single word"
  end

  def test_default_ignores_match_at_any_depth_but_only_whole_names
    ignored = ->(path) { W::DEFAULT_IGNORES.any? { |regexp| regexp.match?(path) } }
    assert ignored.call("sub/node_modules/x")
    assert ignored.call(".git/HEAD")
    refute ignored.call("lib/tmpfile.rb")
    refute ignored.call("my.git/x")
  end
end

class TestWatchRegistry < Minitest::Test
  def setup    = Asgard::Watch.declarations.clear
  def teardown = Asgard::Watch.declarations.clear

  def test_tasks_watch_declares_an_entry
    Tasks.watch :tree, paths: "lib"
    assert_equal "tree", Asgard::Watch.declarations["tree"][:task]
  end

  def test_redeclaring_the_same_entry_is_a_no_op
    2.times { Tasks.watch :tree, paths: "lib", only: /\.rb\z/, events: %i[added changed] }
    assert_equal 1, Asgard::Watch.declarations.size
  end

  def test_redeclaring_a_name_differently_raises
    Tasks.watch :tree, paths: "lib"
    error = assert_raises(ArgumentError) { Tasks.watch :tree, paths: "test" }
    assert_includes error.message, "as:"
  end

  def test_as_allows_watching_one_task_twice
    Tasks.watch :tree, paths: "lib"
    Tasks.watch :tree, paths: "test", as: "tree-test"
    assert_equal %w[tree tree-test], Asgard::Watch.declarations.keys
  end
end

class TestWatchChanges < Minitest::Test
  C = Asgard::Changes

  def setup
    C.forget
    C::VARIABLES.each_value { |variable| ENV.delete(variable) }
  end
  alias teardown setup

  def test_defaults_to_empty_lists
    changes = C.new
    assert_empty changes.modified
    assert_empty changes.all
    assert_predicate changes, :empty?
  end

  def test_from_env_and_to_env_round_trip
    env = { "ASGARD_MODIFIED" => "lib/a.rb\nlib/b c.rb", "ASGARD_ADDED" => "docs/new file.md", "ASGARD_REMOVED" => "" }
    changes = C.from_env(env)
    assert_equal ["lib/a.rb", "lib/b c.rb"], changes.modified
    assert_equal ["docs/new file.md"],      changes.added
    assert_empty changes.removed
    assert_equal env, changes.to_env
    assert_equal changes, C.from_env(changes.to_env)
  end

  def test_from_env_tolerates_missing_variables
    changes = C.from_env({})
    assert_predicate changes, :empty?
    assert_equal({ "ASGARD_MODIFIED" => "", "ASGARD_ADDED" => "", "ASGARD_REMOVED" => "" }, changes.to_env)
  end

  def test_all_is_the_deduplicated_union_in_order
    changes = C.new(modified: %w[b a], added: %w[c a], removed: ["b"])
    assert_equal %w[b a c], changes.all
    refute_predicate changes, :empty?
  end

  def test_paths_are_strings_and_frozen
    changes = C.new(modified: [Pathname.new("lib/a.rb")])
    assert_equal ["lib/a.rb"], changes.modified
    assert_predicate changes.modified, :frozen?
  end

  def test_filter_events_keeps_only_the_declared_kinds
    batch  = { modified: ["m.rb"], added: ["a.rb"], removed: ["r.rb"] }
    events = Asgard::Watch.normalize_events(%i[added removed])
    changes = Asgard::Watch.filter_events(batch, events)
    assert_empty changes.modified
    assert_equal ["a.rb"], changes.added
    assert_equal ["r.rb"], changes.removed
    assert_equal batch.values.flatten, Asgard::Watch.filter_events(batch, Asgard::Watch.normalize_events(:all)).all
  end

  def test_filter_events_is_nil_when_nothing_is_left
    batch = { modified: ["m.rb"], added: [], removed: [] }
    assert_nil Asgard::Watch.filter_events(batch, Asgard::Watch.normalize_events(:added))
    assert_nil Asgard::Watch.filter_events({}, Asgard::Watch.normalize_events(:all))
  end

  def test_kernel_changes_reads_the_trigger_variables_once
    ENV["ASGARD_ADDED"] = "x.rb"
    first = changes
    assert_equal ["x.rb"], first.added
    ENV["ASGARD_ADDED"] = "y.rb"
    assert_same first, changes
    C.forget
    assert_equal ["y.rb"], changes.added
  end

  def test_kernel_changes_is_empty_outside_the_watcher
    assert_predicate changes, :empty?
    assert_predicate Kernel.changes, :empty?
  end
end

class TestWatchSpawn < Minitest::Test
  S = Asgard::Watch::Spawn

  def spec    = Asgard::Watch.normalize(:lint, paths: "lib/**/*.rb", env: { BUILD: "dev", PATH: "/override" }, as: "lint-lib")
  def changes = Asgard::Changes.new(modified: ["lib/a.rb"], added: ["lib/b c.rb"])

  def context(direnv: nil)
    S::Context.new(root: "/proj", log: "/state/watcher.log", base: { "PATH" => "/bin", "HOME" => "/h" },
                   asgard: "/bin/asgard", direnv:)
  end

  def test_base_env_keeps_only_the_whitelist_and_locale_variables
    env = { "PATH" => "/bin", "HOME" => "/h", "LC_ALL" => "C", "LANG" => "en", "SECRET" => "x", "RAILS_ENV" => "dev" }
    assert_equal({ "PATH" => "/bin", "HOME" => "/h", "LC_ALL" => "C", "LANG" => "en" }, S.base_env(env))
    assert_equal ENV.fetch("PATH"), S.base_env["PATH"]
    refute_includes S.base_env.keys, "SECRET"
  end

  def test_regression_w11_base_env_keeps_ruby_and_bundler_settings
    env  = { "GEM_HOME" => "/g", "GEM_PATH" => "/g:/h", "RUBYOPT" => "-W0", "RUBYLIB" => "/l",
             "BUNDLE_GEMFILE" => "/proj/Gemfile", "BUNDLER_VERSION" => "2.6", "SECRET" => "x" }
    kept = Asgard::Watch::Spawn.base_env(env)
    assert_equal env.keys - ["SECRET"], kept.keys
  end

  def test_environment_layers_base_declared_and_trigger_variables
    env = S.environment(spec, changes, context)
    assert_equal "/override", env["PATH"]
    assert_equal "/h",        env["HOME"]
    assert_equal "dev",       env["BUILD"]
    assert_equal "lint-lib",  env["ASGARD_WATCH"]
    assert_equal "/proj",     env["ASGARD_WATCH_ROOT"]
    assert_equal "lib/a.rb",  env["ASGARD_MODIFIED"]
    assert_equal "lib/b c.rb", env["ASGARD_ADDED"]
    assert_equal "",          env["ASGARD_REMOVED"]
    assert_equal changes, Asgard::Changes.from_env(env)
  end

  def test_argv_with_and_without_direnv
    assert_equal %w[/bin/asgard lint],                       S.argv(spec, context)
    assert_equal %w[/bin/direnv exec /proj /bin/asgard lint], S.argv(spec, context(direnv: "/bin/direnv"))
  end

  def test_executable_prefers_the_running_asgard_over_path
    checkout = File.expand_path("../bin/asgard", __dir__)
    assert_equal checkout, S.executable(checkout, "/nowhere")
    assert_equal checkout, S.executable("bin/asgard", "/nowhere") if Dir.pwd == File.dirname(checkout, 2)
    Dir.mktmpdir do |bin|
      File.write(File.join(bin, "asgard"), "")
      File.chmod(0o755, File.join(bin, "asgard"))
      assert_equal File.join(bin, "asgard"), S.executable("-e", bin), "not an executable named asgard: fall back to PATH"
      assert_equal File.join(bin, "asgard"), S.executable(File.join(bin, "ruby"), bin)
    end
    assert_nil S.executable("-e", "/nowhere")
  end

  def test_description_is_complete_and_shareable
    description = S.description(spec, changes, context(direnv: "/bin/direnv"))
    assert Ractor.shareable?(description)
    assert_equal "lint-lib", description[:entry]
    assert_equal "lint",     description[:task]
    assert_equal %w[/bin/direnv exec /proj /bin/asgard lint], description[:argv]
    assert_equal "/proj",              description[:root]
    assert_equal "/state/watcher.log", description[:log]
    assert_equal "/proj",              description[:env]["ASGARD_WATCH_ROOT"]
    assert_equal({ modified: ["lib/a.rb"], added: ["lib/b c.rb"], removed: [] }, description[:changes])
    assert_equal %i[entry task argv env root log changes], description.keys
  end

  def test_description_holds_only_plain_values
    assert plain?(S.description(spec, Asgard::Changes.new, context))
  end

  # Strings, Symbols, nil, and Arrays and Hashes of those: what a worker
  # Ractor can be handed without surprises.
  def plain?(value)
    case value
    when Hash  then value.all? { |key, item| plain?(key) && plain?(item) }
    when Array then value.all? { |item| plain?(item) }
    else [String, Symbol, NilClass].include?(value.class)
    end
  end
end

class TestWatchWorker < Minitest::Test
  Worker  = Asgard::Watch::Worker
  Spawner = Worker::Spawner

  # Stands in for Spawner: hands out pids, and each fake child stays
  # "running" in wait until the test releases it with an exit code.
  class RecordingSpawner
    attr_reader :spawned

    def initialize
      @spawned  = []
      @gates    = {}
      @next_pid = 100
      @mutex    = Mutex.new
    end

    def spawn(description)
      @mutex.synchronize do
        pid = @next_pid += 1
        @spawned << [description[:entry], pid]
        @gates[pid] = Queue.new
        pid
      end
    end

    def wait(pid) = gate(pid).pop

    def release(pid, code = 0) = gate(pid).push(code)

    private

    def gate(pid) = @mutex.synchronize { @gates.fetch(pid) }
  end

  # Wall clock stands still; the monotonic clock advances one second per reading.
  class FakeClock
    def initialize = @tick = 0.0

    def clock_gettime(kind) = kind == Process::CLOCK_REALTIME ? 1_700_000_000.0 : (@tick += 1.0)
  end

  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "watcher.log")
  end

  def teardown = FileUtils.rm_rf(@dir)

  def description(entry, *argv, env: {})
    Ractor.make_shareable(
      { entry:, task: entry, argv: argv.empty? ? ["true"] : argv, env: { "PATH" => ENV.fetch("PATH") }.merge(env),
        root: @dir, log: @log, changes: { modified: ["#{entry}.rb"], added: [], removed: [] } }
    )
  end

  def start_thread(queue, reports, spawner)
    Thread.new { Worker.new(queue, reports, spawner:, clock: FakeClock.new).run }
  end

  def test_run_serializes_one_tasks_triggers_and_reports_each
    queue = Queue.new
    reports = Queue.new
    spawner = RecordingSpawner.new
    thread = start_thread(queue, reports, spawner)
    2.times { queue.push(description("test")) }

    first = reports.pop
    assert_equal(
      { kind: :spawn, entry: "test", task: "test", pid: 101, at: 1_700_000_000.0,
        changes: { modified: ["test.rb"], added: [], removed: [] } }, first
    )
    sleep 0.05
    assert_equal [["test", 101]], spawner.spawned, "second trigger must wait for the first child"

    spawner.release(101, 3)
    assert_equal({ kind: :exit, entry: "test", task: "test", pid: 101, at: 1_700_000_000.0, status: 3, seconds: 1.0 }, reports.pop)
    assert_equal 102, reports.pop[:pid]
    spawner.release(102)
    assert_equal 0, reports.pop[:status]

    queue.push(nil)
    thread.join
  end

  def test_two_workers_run_different_tasks_at_once
    reports = Queue.new
    spawner = RecordingSpawner.new
    queues  = [Queue.new, Queue.new]
    threads = queues.map { |queue| start_thread(queue, reports, spawner) }
    queues[0].push(description("lint"))
    queues[1].push(description("docs"))

    started = Array.new(2) { reports.pop }
    assert_equal %w[docs lint], started.map { |report| report[:entry] }.sort, "both spawned before either child exited"

    spawner.spawned.map(&:last).each { |pid| spawner.release(pid) }
    2.times { reports.pop }
    queues.each { |queue| queue.push(nil) }
    threads.each(&:join)
  end

  def test_reports_are_shareable
    queue = Queue.new
    reports = Queue.new
    spawner = RecordingSpawner.new
    thread = start_thread(queue, reports, spawner)
    queue.push(description("x"))
    assert Ractor.shareable?(reports.pop)
    spawner.release(101)
    assert Ractor.shareable?(reports.pop)
    queue.push(nil)
    thread.join
  end

  def test_spawner_runs_the_task_isolated_and_logs_its_output
    ENV["ASGARD_TEST_SECRET"] = "leak"
    spec = description("echo", "sh", "-c", "echo out=$ASGARD_TEST_SECRET$ASGARD_WATCH; echo err >&2; pwd",
                       env: { "ASGARD_WATCH" => "echo" })
    pid  = Spawner.spawn(spec)
    assert_equal 0, Spawner.wait(pid)
    assert_equal ["out=echo", "err", File.realpath(@dir)], File.readlines(@log, chomp: true)
  ensure
    ENV.delete("ASGARD_TEST_SECRET")
  end

  def test_spawner_exit_codes_for_failures_and_signals
    assert_equal 3,   Spawner.wait(Spawner.spawn(description("f", "sh", "-c", "exit 3")))
    assert_equal 137, Spawner.wait(Spawner.spawn(description("k", "sh", "-c", "kill -9 $$")))
  end

  def test_start_runs_real_processes_in_a_ractor
    queue   = RactorQueue.new(capacity: 16)
    reports = RactorQueue.new(capacity: 16)
    inbox   = Asgard::Watch::Mailbox.new(queue, Worker.start(queue, reports))
    inbox.push(description("ok"))
    inbox.push(description("bad", "sh", "-c", "echo hi; exit 3"))
    inbox.push(nil)

    received = Array.new(4) { reports.pop(timeout: 10) }
    assert_equal(%i[spawn exit spawn exit], received.map { |report| report[:kind] })
    assert_equal(%w[ok ok bad bad],         received.map { |report| report[:entry] })
    assert_equal([0, 3],                    received.select { |report| report[:kind] == :exit }.map { |report| report[:status] })
    assert_equal received[0][:pid], received[1][:pid]
    assert_includes File.read(@log), "hi"
  end
end

# Stands in for Watch::State: keeps the latest record per entry in memory.
class MemoryState
  attr_reader :entries

  def initialize = @entries = {}

  def write_entry(name, record) = @entries[name] = record
end

class TestWatchReporter < Minitest::Test
  Reporter = Asgard::Watch::Reporter
  AT       = Time.new(2026, 10, 18, 9, 30, 0).to_f
  CHANGES  = { modified: ["lib/a.rb"], added: ["new file.rb"], removed: [] }.freeze

  def setup
    @dir   = Dir.mktmpdir
    @log   = File.join(@dir, "watcher.log")
    @state = MemoryState.new
    @queue = Queue.new
    @reporter = Reporter.new(@queue, log: @log, state: @state)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def trigger(entry = "lint", task = entry) = { kind: :trigger, entry:, task:, at: AT, changes: CHANGES }
  def spawn(pid, entry = "lint", task = entry) = { kind: :spawn, entry:, task:, pid:, at: AT, changes: CHANGES }

  def exit_report(pid, status = 0, entry = "lint", task = entry)
    { kind: :exit, entry:, task:, pid:, at: AT + 2.5, status:, seconds: 2.5 }
  end

  def test_regression_w12_a_failed_log_write_does_not_end_the_reporter
    reporter = Reporter.new(@queue, log: File.join(@dir, "gone", "watcher.log"), state: @state)
    thread   = reporter.start
    @queue.push(spawn(7))
    @queue.push(exit_report(7))
    @queue.push(nil)
    _, err = capture_io { thread.join(5) }
    refute thread.alive?
    assert_empty reporter.running, "the exit was still tracked"
    assert_equal 0, @state.entries["lint"][:status]
    assert_match(/could not write/, err)
  end

  # E4 (X1): the watcher log is rotated once it passes its size limit,
  # keeping one previous file.
  def test_regression_x1_the_log_rotates_past_its_limit
    reporter = Reporter.new(@queue, log: @log, state: @state, max_log: 200)
    File.write(@log, "x" * 250)
    reporter.handle(trigger)
    assert_equal "x" * 250, File.read("#{@log}.1")
    assert_operator File.size(@log), :<, 200
    reporter.handle(trigger)
    assert_equal "x" * 250, File.read("#{@log}.1"), "a small log is left alone"
  end

  def test_regression_x1_rotate_is_pure_enough
    path = File.join(@dir, "r.log")
    refute Asgard::StateDir.rotate(path, max_bytes: 10), "no file, nothing to do"
    File.write(path, "12345")
    refute Asgard::StateDir.rotate(path, max_bytes: 10)
    File.write(path, "x" * 11)
    assert Asgard::StateDir.rotate(path, max_bytes: 10)
    refute File.exist?(path)
    assert_equal 10_485_760, Asgard::StateDir.log_limit({})
    assert_equal 2048, Asgard::StateDir.log_limit({ "ASGARD_LOG_MAX" => "2048" })
    assert_equal 10_485_760, Asgard::StateDir.log_limit({ "ASGARD_LOG_MAX" => "lots" })
  end

  def test_log_lines
    assert_equal "2026-10-18 09:30:00 trigger lint task=lint lib/a.rb new file.rb", Reporter.log_line(trigger)
    assert_equal "2026-10-18 09:30:00 trigger lint task=lint lib/a.rb new file.rb (queued behind pid 41)",
                 Reporter.log_line(trigger, behind: 41)
    assert_equal "2026-10-18 09:30:00 spawn lint task=lint pid=41 lib/a.rb new file.rb", Reporter.log_line(spawn(41))
    assert_equal "2026-10-18 09:30:02 exit lint task=lint pid=41 status=3 seconds=2.50", Reporter.log_line(exit_report(41, 3))
  end

  def test_entry_record_starts_on_spawn_and_completes_on_exit
    started = Reporter.entry_record(spawn(41))
    assert_equal({ entry: "lint", task: "lint", pid: 41, started: Time.at(AT).iso8601, changes: CHANGES }, started)
    finished = Reporter.entry_record(exit_report(41, 3), started)
    assert_equal started.merge(finished: Time.at(AT + 2.5).iso8601, status: 3, seconds: 2.5), finished
    orphan = Reporter.entry_record(exit_report(41))
    assert_equal %i[entry task pid finished status seconds], orphan.keys
  end

  def test_handle_writes_the_log_and_entry_and_tracks_pids
    @reporter.handle(trigger)
    @reporter.handle(spawn(41))
    assert_equal [41], @reporter.running
    assert_equal 41, @reporter.running_for("lint")
    assert_nil @reporter.running_for("docs")
    refute @state.entries["lint"].key?(:finished)

    @reporter.handle(trigger)
    @reporter.handle(exit_report(41, 2))
    assert_empty @reporter.running
    assert_equal 2, @state.entries["lint"][:status]

    lines = File.readlines(@log, chomp: true)
    assert_equal 4, lines.size
    assert_match(/queued behind pid 41\)\z/, lines[2])
    refute_match(/queued/, lines[0])
  end

  def test_run_handles_until_nil
    thread = @reporter.start
    @queue.push(spawn(7, "a"))
    @queue.push(spawn(8, "b"))
    @queue.push(nil)
    thread.join
    assert_equal [7, 8], @reporter.running
    assert_equal %w[a b], @state.entries.keys
  end
end

class TestWatchDispatcher < Minitest::Test
  Dispatcher = Asgard::Watch::Dispatcher

  def setup
    @started = []
    @reports = Queue.new
    @context = Asgard::Watch::Spawn::Context.new(root: "/proj", log: "/log", base: { "PATH" => "/bin" }, asgard: "/bin/asgard", direnv: nil)
    @declarations = {
      "lint"     => Asgard::Watch.normalize(:lint, paths: "lib/**/*.rb"),
      "lint-doc" => Asgard::Watch.normalize(:lint, paths: "docs/**/*.md", as: "lint-doc", events: :added),
      "test"     => Asgard::Watch.normalize(:test, paths: "test/**/*.rb")
    }
    start = lambda do |queue, reports|
      @started << [queue, reports]
      :ractor
    end
    @dispatcher = Dispatcher.new(@declarations, @context, reports: @reports, start:)
  end

  def batch(**lists) = { modified: [], added: [], removed: [] }.merge(lists)

  def test_one_worker_per_task_shared_by_declarations_of_the_same_task
    assert_equal %w[lint test], @dispatcher.workers.keys
    assert_equal %w[lint lint-doc test], @dispatcher.dispatch.keys
    assert_equal 2, @started.size
    assert_equal @dispatcher.workers["lint"][:queue], @started[0][0]
    assert_same @reports, @started[0][1]
    assert_equal :ractor, @dispatcher.workers["test"][:ractor]
    assert_predicate @dispatcher.workers, :frozen?
  end

  def test_route_builds_the_description_reports_the_trigger_and_queues_it
    description = @dispatcher.route("lint-doc", batch(added: ["docs/x.md"]))
    assert_equal "lint-doc", description[:entry]
    assert_equal "lint",     description[:task]
    assert_equal ["docs/x.md"], description[:changes][:added]
    assert_same description, @dispatcher.workers["lint"][:queue].pop
    report = @reports.pop
    assert_equal %i[kind entry task at changes], report.keys
    assert_equal [:trigger, "lint-doc", "lint"], report.values_at(:kind, :entry, :task)
    assert Ractor.shareable?(report)
  end

  def test_route_skips_a_batch_filtered_to_nothing
    assert_nil @dispatcher.route("lint-doc", batch(modified: ["docs/x.md"]))
    assert_empty @reports
    assert_predicate @dispatcher.workers["lint"][:queue], :empty?
  end

  def test_run_routes_until_nil_without_waiting_on_workers
    inbox  = Queue.new
    thread = @dispatcher.start(inbox)
    inbox.push(["lint", batch(modified: ["lib/a.rb"])])
    inbox.push(["test", batch(modified: ["test/b.rb"])])
    inbox.push(["lint", batch(modified: ["lib/c.rb"])])
    inbox.push(nil)
    thread.join
    assert_equal 1, @dispatcher.workers["lint"][:queue].size, "the two lint triggers merged (W15)"
    assert_equal 1, @dispatcher.workers["test"][:queue].size
    assert_equal 3, @reports.size
  end
end

class TestWatchState < Minitest::Test
  State = Asgard::Watch::State

  def setup
    @home  = Dir.mktmpdir
    @base  = State.base_dir(home: @home, env: {})
    @state = State.new(project: "My Proj", root: "/proj", base: @base)
  end

  def teardown = FileUtils.rm_rf(@home)

  def test_regression_w6_the_lock_is_held_by_one_holder_at_a_time
    first = @state.acquire_lock
    assert first, "the first holder gets the lock"
    assert_nil @state.acquire_lock, "a second open of the lock file is refused"
    first.close
    second = @state.acquire_lock
    assert second, "released on close"
    second.close
  end

  def test_regression_w6_an_inherited_lock_is_adopted_only_when_it_is_the_lock_file
    held = @state.acquire_lock
    adopted = @state.adopt_lock({ State::LOCK_ENV => held.fileno.to_s })
    assert_equal held.fileno, adopted&.fileno
    adopted.autoclose = false # same descriptor as held, which closes it
    File.open(File::NULL) do |other|
      assert_nil @state.adopt_lock({ State::LOCK_ENV => other.fileno.to_s }), "an unrelated fd is never adopted"
    end
    assert_nil @state.adopt_lock({ State::LOCK_ENV => "999999" }), "a closed fd"
    assert_nil @state.adopt_lock({}), "nothing inherited"
  ensure
    held&.close
  end

  def test_paths_live_under_the_state_home
    dir = File.join(@home, ".local", "state", "asgard", "watch", "my-proj")
    assert_equal dir, @state.dir
    assert_equal File.join(dir, "watcher.pid"),        @state.pid_path
    assert_equal File.join(dir, "watcher.log"),        @state.log_path
    assert_equal File.join(dir, "entries", "lint.json"), @state.entry_path("lint")
    assert_equal "/xdg/asgard/watch", State.base_dir(home: @home, env: { "XDG_STATE_HOME" => "/xdg" })
    assert_equal File.join(Dir.home, ".local", "state", "asgard", "watch"), State.base_dir(env: {})
  end

  def test_prepare_records_the_root_and_all_finds_it
    @state.prepare
    assert_equal "/proj\n", File.read(@state.root_path)
    State.new(project: "other", root: "/other", base: @base).prepare
    assert_equal [["my-proj", "/proj"], ["other", "/other"]], State.all(base: @base)
  end

  def test_pidfile_round_trip_and_liveness
    @state.prepare
    assert_nil @state.read_pid
    assert_nil @state.running_pid
    @state.write_pid(Process.pid)
    assert_equal Process.pid, @state.read_pid
    assert_equal Process.pid, @state.running_pid
    dead = Process.spawn("true")
    Process.wait(dead)
    @state.write_pid(dead)
    assert_nil @state.running_pid, "a stale pidfile is not a running daemon"
    @state.clear
    assert_nil @state.read_pid
  end

  def test_entries_round_trip_through_json
    record = { entry: "lint", task: "lint", pid: 41, started: "2026-10-18T09:30:00-05:00",
               changes: { modified: ["a.rb"], added: [], removed: [] } }
    assert_nil @state.read_entry("lint")
    @state.write_entry("lint", record)
    assert_equal record, @state.read_entry("lint")
    @state.write_entry("docs", record.merge(entry: "docs", status: 0))
    assert_equal %w[docs lint], @state.entries.keys
    assert_equal 0, @state.entries["docs"][:status]
    assert_empty Dir.glob(File.join(@state.entries_dir, "asgard*")), "no tempfile left behind"
  end

  # W14: a task named "t" is not every asgard command line with a t in it.
  def test_regression_w14_running_matches_the_task_as_a_whole_word
    asgard = "/usr/local/bin/asgard"
    assert State.task_process?("lint", command: "/opt/homebrew/bin/direnv exec /proj #{asgard} lint")
    refute State.task_process?("t", command: "ruby #{asgard} test_check")
    refute State.task_process?("lint", command: "/bin/sleep lint")
    refute State.task_process?("lint", command: nil)
  end

  def test_declarations_round_trip
    specs = [Asgard::Watch.normalize(:lint, paths: "lib/**/*.rb", events: :added)]
    assert_empty @state.read_declarations
    @state.write_declarations(specs)
    assert_equal [{ name: "lint", task: "lint", paths: ["lib/**/*.rb"], events: ["added"] }], @state.read_declarations
  end
end

# W2: a spawn that raises must not end the worker, a full worker queue
# must not stall routing, and change lists too big for the environment
# travel in a file instead.
# W2 regressions.
class TestWatchWorker
  # RecordingSpawner whose first spawn raises +error+.
  class RaisingSpawner < RecordingSpawner
    def initialize(error)
      super()
      @error = error
    end

    def spawn(description)
      error = @error
      @error = nil
      raise error if error

      super
    end
  end

  def test_regression_w2_a_spawn_error_is_reported_and_the_worker_lives_on
    queue   = Queue.new
    reports = Queue.new
    spawner = RaisingSpawner.new(Errno::E2BIG.new)
    thread  = start_thread(queue, reports, spawner)
    2.times { queue.push(description("lint")) }
    failed = Timeout.timeout(5) { reports.pop }
    assert_equal [:exit, "lint", nil, 126], failed.values_at(:kind, :entry, :pid, :status)
    assert_match(/Argument list too long/, failed[:error])
    spawned = Timeout.timeout(5) { reports.pop }
    assert_equal :spawn, spawned[:kind], "the next trigger still runs"
    spawner.release(spawned[:pid], 0)
    assert_equal :exit, Timeout.timeout(5) { reports.pop }[:kind]
  ensure
    queue&.push(nil)
    thread&.join(5)
  end

  def test_regression_w2_a_real_ractor_survives_a_missing_root
    queue   = RactorQueue.new(capacity: 16)
    reports = RactorQueue.new(capacity: 16)
    inbox   = Asgard::Watch::Mailbox.new(queue, Worker.start(queue, reports))
    missing = Ractor.make_shareable(description("gone").merge(root: File.join(@dir, "no", "such", "dir")))
    inbox.push(missing)
    inbox.push(description("ok"))
    inbox.push(nil)
    received = Array.new(3) { reports.pop(timeout: 10) }
    assert_equal(%i[exit spawn exit], received.map { |report| report[:kind] })
    assert_equal 127, received[0][:status]
    assert_equal 0,   received[2][:status]
  end

  def test_regression_w2_reporter_logs_a_spawn_error
    line = Asgard::Watch::Reporter.log_line({ kind: :exit, entry: "lint", task: "lint", pid: nil, at: 0, status: 126,
                                              seconds: 0.0, error: "Argument list too long" })
    assert_match(/status=126 .*error=Argument list too long/, line)
  end
end

# W4: a task must never read the daemon's stdin. The test's own stdin is
# swapped for a pipe nobody writes to, so a child that inherits it blocks
# in `read`, while one given /dev/null sees end-of-file at once.
class TestWatchWorker
  # Yields with fd 0 a pipe whose write end stays open (and silent) until
  # the block returns, so the block must also wait for its child.
  def with_silent_stdin
    reader, writer = IO.pipe
    saved = $stdin.dup
    $stdin.reopen(reader)
    yield -> { $stdin.reopen(saved) }
  ensure
    $stdin.reopen(saved) if saved
    [reader, writer, saved].each { |io| io&.close }
  end

  def test_regression_w4_spawn_options_detach_stdin
    options = Spawner.spawn_options(description("lint"))
    assert_equal File::NULL, options[:in]
    assert_equal({ chdir: @dir, pgroup: true, unsetenv_others: true, out: [@log, "a"], err: %i[child out] },
                 options.except(:in))
  end

  def test_regression_w4_a_task_that_reads_stdin_sees_end_of_file
    pid    = nil
    status = nil
    with_silent_stdin do |restore|
      pid = Spawner.spawn(description("reader", "sh", "-c", 'read line; echo "read=$?"'))
      restore.call
      status = Timeout.timeout(3) { Spawner.wait(pid) }
    end
    assert_equal 0, status
    assert_includes File.read(@log), "read=1"
  ensure
    if pid && Asgard::Pid.alive?(pid)
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end

  def test_regression_w4_the_daemon_is_started_without_stdin
    options = Asgard::Watch::Commands.daemon_spawn_options("/proj", "/proj/watcher.log")
    assert_equal({ chdir: "/proj", pgroup: true, in: File::NULL, out: ["/proj/watcher.log", "a"], err: %i[child out] }, options)
  end
end

# W2 regressions.
class TestWatchDispatcher
  def test_regression_w2_a_full_worker_queue_drops_the_trigger_instead_of_blocking
    queue = @dispatcher.workers["lint"][:queue]
    nil while queue.try_push(Ractor.make_shareable({ filler: true }))
    result = Timeout.timeout(2) { @dispatcher.route("lint", batch(modified: ["lib/a.rb"])) }
    assert_nil result, "nothing was queued"
    kinds = Array.new(@reports.size) { @reports.pop[:kind] }
    assert_equal %i[trigger dropped], kinds
  end
end

# E2 (W15): triggers waiting for a busy task merge.
class TestWatchDispatcher
  def drain(queue)
    items = []
    until (item = queue.try_pop).equal?(RactorQueue::EMPTY)
      items << item
    end
    items
  end

  def test_regression_w15_triggers_waiting_for_one_entry_merge_into_one_run
    @dispatcher.route("lint", batch(modified: ["lib/a.rb"]))
    @dispatcher.route("lint", batch(modified: ["lib/b.rb", "lib/a.rb"], added: ["lib/c.rb"]))
    @dispatcher.route("lint", batch(removed: ["lib/d.rb"]))
    pending = drain(@dispatcher.workers["lint"][:queue])
    assert_equal 1, pending.size, "one run with every change, not three"
    assert_equal({ modified: ["lib/a.rb", "lib/b.rb"], added: ["lib/c.rb"], removed: ["lib/d.rb"] }, pending.first[:changes])
    assert_equal "lib/a.rb\nlib/b.rb", pending.first[:env]["ASGARD_MODIFIED"]
  end

  def test_regression_w15_different_entries_of_one_task_stay_apart
    @dispatcher.route("lint", batch(modified: ["lib/a.rb"]))
    @dispatcher.route("lint-doc", batch(added: ["docs/x.md"]))
    @dispatcher.route("lint", batch(modified: ["lib/b.rb"]))
    pending = drain(@dispatcher.workers["lint"][:queue])
    assert_equal(%w[lint-doc lint], pending.map { |item| item[:entry] })
    assert_equal ["lib/a.rb", "lib/b.rb"], pending.last[:changes][:modified]
  end

  def test_regression_w15_merge_changes_is_pure
    merged = Asgard::Watch.merge_changes([Asgard::Changes.new(modified: %w[a b]), Asgard::Changes.new(modified: %w[b c], removed: %w[d])])
    assert_equal [%w[a b c], [], %w[d]], [merged.modified, merged.added, merged.removed]
  end
end

class TestRegressionChangesFile < Minitest::Test
  Spawn = Asgard::Watch::Spawn

  def test_regression_w2_oversized_change_lists_move_to_a_file
    changes = Asgard::Changes.new(modified: Array.new(50) { |i| "lib/file_#{i}.rb" })
    assert_equal changes.to_env, Spawn.change_env(changes, "/state/c.json", limit: 1_000_000)
    assert_equal({ "ASGARD_CHANGES_FILE" => "/state/c.json" }, Spawn.change_env(changes, "/state/c.json", limit: 100))
    assert_equal changes.to_env, Spawn.change_env(changes, nil, limit: 100), "no file to spill to: keep the env"
  end

  def test_regression_w2_the_dispatcher_spills_and_the_worker_cleans_up
    Dir.mktmpdir do |dir|
      context = Spawn::Context.new(root: dir, log: File.join(dir, "watcher.log"), base: {}, asgard: "/bin/asgard", direnv: nil)
      decls   = { "lint" => Asgard::Watch.normalize(:lint, paths: "lib") }
      reports = Queue.new
      dispatcher = Asgard::Watch::Dispatcher.new(decls, context, reports:, start: ->(_q, _r) { :ractor })
      huge = Array.new(20_000) { |i| "lib/some/deeply/nested/file_#{i}.rb" }
      description = dispatcher.route("lint", { modified: huge, added: [], removed: [] })
      path = description[:changes_file]
      assert_equal path, description[:env]["ASGARD_CHANGES_FILE"]
      refute description[:env].key?("ASGARD_MODIFIED")
      assert_equal huge, Asgard::Changes.from_file(path).modified
      Asgard::Watch::Worker.remove_changes_file(path)
      refute File.exist?(path)
      assert_nil Asgard::Watch::Worker.remove_changes_file(path), "already gone is fine"
    end
  end

  def test_regression_w2_changes_read_back_from_the_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "c.json")
      File.write(path, JSON.generate({ modified: ["a.rb"], added: ["b.rb"], removed: [] }))
      changes = Asgard::Changes.from_env({ "ASGARD_CHANGES_FILE" => path })
      assert_equal [["a.rb"], ["b.rb"], []], [changes.modified, changes.added, changes.removed]
    end
  end
end

class TestWatchMailbox < Minitest::Test
  Mailbox = Asgard::Watch::Mailbox

  def test_a_ractor_sleeps_until_a_push_wakes_it
    queue  = RactorQueue.new(capacity: 4)
    ractor = Ractor.new(queue) { |q| Asgard::Watch::Mailbox.new(q, Ractor.current).pop }
    sleep 0.2 # it is now blocked in Ractor.receive
    Mailbox.new(queue, ractor).push(:hello)
    assert_equal :hello, ractor.value
  end

  def test_try_push_reports_a_full_queue_and_pop_returns_nil_payloads
    mailbox = Mailbox.new(RactorQueue.new(capacity: 1), nil)
    assert mailbox.try_push(nil)
    nil while mailbox.try_push(:more)
    refute mailbox.try_push(:overflow)
    assert_nil mailbox.pop, "a pushed nil is a payload, not emptiness"
  end

  def test_ringing_an_ended_ractor_or_a_stand_in_is_harmless
    ended = Ractor.new { :done }
    ended.value
    assert_nil Mailbox.ring(ended)
    assert_nil Mailbox.ring(:ractor)
  end
end

# Stands in for Listen: records each `to` call and exposes the callbacks.
class FakeListen
  Listener = Struct.new(:dirs, :options, :callback, :started) do
    def start = self.started = true
    def stop  = self.started = false
  end

  attr_reader :listeners

  def initialize = @listeners = []

  def to(*dirs, **options, &callback) = Listener.new(dirs, options, callback, false).tap { |listener| @listeners << listener }
end

class TestWatchDaemon < Minitest::Test
  Daemon = Asgard::Watch::Daemon
  # The task files always load: the fake asgard here is not a real one.
  VALID  = ->(_asgard, _root) { true }

  def setup
    @cwd  = Dir.pwd
    @tmp  = Dir.mktmpdir
    @root = File.join(File.realpath(@tmp), "proj")
    FileUtils.mkdir_p(@root)
    @home = File.join(@tmp, "home")
    @asgard = File.join(@tmp, "asgard")
    File.write(@asgard, <<~SH)
      #!/bin/sh
      echo "ran $1 modified=$ASGARD_MODIFIED"
      until [ -f "$ASGARD_WATCH_ROOT/go" ]; do sleep 0.02; done
      exit 4
    SH
    File.chmod(0o755, @asgard)
    @state   = Asgard::Watch::State.new(project: "proj", root: @root, base: Asgard::Watch::State.base_dir(home: @home, env: {}))
    @context = Asgard::Watch::Spawn::Context.new(root: @root, log: @state.log_path, base: { "PATH" => ENV.fetch("PATH") },
                                                 asgard: @asgard, direnv: nil)
    @listen  = FakeListen.new
    @execs   = []
    @out     = StringIO.new
    @saved_traps = %w[INT TERM].to_h { |signal| [signal, trap(signal, "DEFAULT")] }
  end

  def teardown
    @saved_traps&.each { |signal, handler| trap(signal, handler) }
    Dir.chdir(@cwd)
    FileUtils.rm_rf(@tmp)
  end

  # options: replace the stand-ins (exec:, out:, validate:, grace:, ...);
  # config: adds Config members (pending:).
  def daemon(declarations, tasks: %w[lint docs], config: {}, **)
    config = Daemon::Config.new(declarations:, root: @root, state: @state, context: @context, tasks:, **config)
    Daemon.new(config, listen: @listen, exec: ->(*argv) { @execs << argv }, out: @out, validate: VALID, **)
  end

  def declarations
    { "lint" => Asgard::Watch.normalize(:lint, paths: "lib/**/*.rb", debounce: 0.1),
      "docs" => Asgard::Watch.normalize(:docs, paths: "docs", only: /\.md\z/, events: :added) }
  end

  def wait_until(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.02 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert yield, "condition not met within #{seconds}s"
  end

  def test_listen_options_and_unknown_tasks
    assert_equal({ only: /\.md\z/, ignore!: [*Asgard::Watch::DEFAULT_IGNORES, :editor], wait_for_delay: 0.5, relative: true },
                 Daemon.listen_options(declarations["docs"], "docs", editor: :editor))
    refute_includes Daemon.listen_options(Asgard::Watch.normalize(:t, paths: "lib"), "lib").keys, :only
    assert_equal ["docs"], Daemon.unknown_tasks(declarations, %w[lint])
    error = assert_raises(Asgard::Watch::Error) { daemon(declarations, tasks: ["lint"]).run }
    assert_includes error.message, "docs"
  end

  def test_run_watches_each_declaration_runs_a_task_and_stops_after_it_exits
    watcher = daemon(declarations)
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }

    assert_equal 3, @listen.listeners.size
    lint, docs, loki = @listen.listeners
    assert_equal ["lib"],   lint.dirs
    assert_equal ["docs"],  docs.dirs
    assert_equal [@root],   loki.dirs
    assert_match loki.options[:only], ".loki"
    refute_match loki.options[:only], "test/fixtures/.loki"
    assert_equal 0.1, lint.options[:wait_for_delay]
    assert @listen.listeners.all?(&:started)
    assert_equal @root, Dir.pwd

    lint.callback.call(["lib/a.rb"], [], [])
    wait_until { @state.read_entry("lint")&.key?(:pid) }
    refute @state.read_entry("lint").key?(:finished)

    watcher.stop
    sleep 0.3
    assert thread.alive?, "shutdown waits for the running task"
    assert File.exist?(@state.pid_path)
    refute @listen.listeners.any?(&:started)

    FileUtils.touch(File.join(@root, "go"))
    thread.join
    refute File.exist?(@state.pid_path)
    assert_equal 4, @state.read_entry("lint")[:status]
    assert_includes File.read(@state.log_path), "ran lint modified=lib/a.rb"
    assert_includes @out.string, "waiting for pid"
    assert_includes @out.string, "stopped"
  ensure
    FileUtils.touch(File.join(@root, "go"))
    thread&.join
  end

  def test_loki_change_reloads_by_exec
    watcher = daemon(declarations)
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }
    @listen.listeners.last.callback.call([".loki"], [], [])
    wait_until { @execs.any? }
    assert_equal([[@asgard, "watcher", "run"]], @execs.map { |argv| argv.grep(String) })
    refute @listen.listeners.any?(&:started)
    assert_includes @out.string, "watcher: reloading"
  ensure
    watcher&.stop
    thread&.join
  end
end

# W1: a .loki change must re-exec the daemon. Real Listen, because the
# failure (a listener stopping itself from its own callback thread) is
# Listen's, and the fake one runs callbacks on the caller's thread.
# W1 regressions.
class TestWatchDaemon
  def test_regression_w1_a_real_loki_change_reaches_exec
    FileUtils.mkdir_p [File.join(@root, "lib"), File.join(@root, "docs")]
    File.write(File.join(@root, ".loki"), "# v1\n")
    config  = Daemon::Config.new(declarations:, root: @root, state: @state, context: @context, tasks: %w[lint docs])
    watcher = Daemon.new(config, listen: Daemon.listen_module, exec: ->(*argv) { @execs << argv }, out: @out, validate: VALID)
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }
    sleep 1 # FSEvents / inotify need a moment before they report
    File.write(File.join(@root, ".loki"), "# v2\n")
    wait_until(10) { @execs.any? }
    assert_equal([[@asgard, "watcher", "run"]], @execs.map { |argv| argv.grep(String) })
    assert thread.join(5), "run returns once the (stand-in) exec returns"
  ensure
    watcher&.stop
    thread&.join(5)
  end

  # W3: a stop that lands while a trigger is still being routed must not
  # return with that trigger about to spawn. The dispatcher stand-in
  # routes slowly, so shutdown always overtakes it; the fake asgard exits
  # at once (go exists).
  class SlowDispatcher < Asgard::Watch::Dispatcher
    def route(id, batch)
      sleep 0.3
      super
    end
  end

  def test_regression_w3_shutdown_waits_for_a_trigger_being_routed
    FileUtils.touch(File.join(@root, "go"))
    config  = Daemon::Config.new(declarations:, root: @root, state: @state, context: @context, tasks: %w[lint docs])
    watcher = Daemon.new(config, listen: @listen, exec: ->(*argv) { @execs << argv }, out: @out, dispatcher: SlowDispatcher,
                                 validate: VALID)
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }
    @listen.listeners.first.callback.call(["lib/a.rb"], [], [])
    sleep 0.05 # the dispatcher has popped the batch and is inside route
    watcher.stop
    assert thread.join(10), "run returns"
    returned = File.exist?(@state.log_path) ? File.read(@state.log_path) : ""
    sleep 1
    after = File.exist?(@state.log_path) ? File.read(@state.log_path) : ""
    assert_equal returned, after, "nothing may happen after run returned"
    spawns = after.scan(/ spawn lint task=lint pid=(\d+)/).flatten
    exits  = after.scan(/ exit lint task=lint pid=(\d+)/).flatten
    assert_equal spawns, exits, "every spawned task has an exit record"
  ensure
    thread&.join(5)
  end

  def test_regression_w3_close_queue_drops_waiting_triggers_and_ends_the_worker
    queue = RactorQueue.new(capacity: 4)
    3.times { |i| queue.push(i) }
    Daemon.close_queue(Asgard::Watch::Mailbox.new(queue, nil))
    assert_nil queue.pop(timeout: 1), "only the closing nil is left"
    assert_predicate queue, :empty?
  end

  def test_regression_w3_join_worker_tolerates_a_dead_worker
    dead = Ractor.new { raise "worker died" }
    capture_io { assert_nil Daemon.join_worker(dead) }
    assert_equal 42, Daemon.join_worker(Ractor.new { 42 }) && 42
  end

  # W5: an idle daemon (two workers, the reporter, the dispatcher) must
  # not burn CPU waiting. Spinning queues cost about 0.12s per 2s here.
  def test_regression_w5_an_idle_daemon_uses_almost_no_cpu
    watcher = daemon(declarations)
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }
    sleep 0.5
    cpu    = -> { Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) }
    before = cpu.call
    sleep 2
    used = cpu.call - before
    assert_operator used, :<, 0.03, "idle CPU over 2s: #{used.round(3)}s"
  ensure
    watcher&.stop
    thread&.join(10)
  end

  def test_regression_w6_a_daemon_refuses_to_run_while_another_holds_the_lock
    held  = @state.prepare.acquire_lock
    error = assert_raises(Asgard::Watch::Error) { daemon(declarations).run }
    assert_match(/another watcher is already running/, error.message)
    assert_empty @listen.listeners, "nothing was started"
  ensure
    held&.close
  end

  # W10: the signal traps are in place while the listeners start (which
  # can take seconds on a big tree), and a start that fails leaves no
  # pidfile and no held lock behind.
  class ProbeListen < FakeListen
    attr_reader :handlers

    def initialize(fail_on_start:)
      super()
      @fail     = fail_on_start
      @handlers = []
    end

    def to(*, **, &)
      listener = super
      probe    = self
      fail     = @fail
      listener.define_singleton_method(:start) do
        previous = trap("TERM", "DEFAULT")
        trap("TERM", previous)
        probe.handlers << previous
        raise "listen could not start" if fail

        self.started = true
      end
      listener
    end
  end

  def test_regression_w10_traps_come_first_and_a_failed_start_cleans_up
    @listen = ProbeListen.new(fail_on_start: true)
    error = assert_raises(RuntimeError) { daemon(declarations).run }
    assert_equal "listen could not start", error.message
    assert_kind_of Proc, @listen.handlers.first, "TERM is trapped before the listeners start"
    refute File.exist?(@state.pid_path)
    lock = @state.acquire_lock
    assert lock, "the lock was released"
  ensure
    lock&.close
  end

  # W13: only the task files asgard loaded, plus .loki files beside the
  # root one (an `import "*.loki"` may pick up a new one), reload the
  # daemon; a .loki deep in fixtures or vendored code does not.
  def test_regression_w13_only_loaded_and_root_level_loki_files_reload
    pattern = Daemon.loki_pattern(@root, [File.join(@root, ".loki"), File.join(@root, "tasks", "gem.loki"),
                                          "/elsewhere/x.loki", File.join(@root, "lib", "x.rb")])
    [".loki", "quality.loki", "tasks/gem.loki"].each { |path| assert_match pattern, path }
    ["test/fixtures/.loki", "tasks/other.loki", "lib/x.rb", "x.loki.bak"].each { |path| refute_match pattern, path }
  end

  # E3 (W16): a .loki saved with an error must not replace a working
  # daemon with one that aborts; the old declarations keep watching.
  def test_regression_w16_a_broken_loki_keeps_the_running_daemon
    config  = Daemon::Config.new(declarations:, root: @root, state: @state, context: @context, tasks: %w[lint docs])
    checked = []
    watcher = Daemon.new(config, listen: @listen, exec: ->(*argv) { @execs << argv }, out: @out,
                                 validate: ->(asgard, root) { (checked << [asgard, root]) && false })
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }
    @listen.listeners.last.callback.call([".loki"], [], [])
    wait_until { checked.any? }
    sleep 0.5
    assert_empty @execs, "no exec into a .loki that does not load"
    assert thread.alive?
    assert @listen.listeners.all?(&:started), "still listening"
    assert_match(/keeping the running declarations/, @out.string)
    assert_equal [[@asgard, @root]], checked
  ensure
    watcher&.stop
    thread&.join(10)
  end

  # W18: the reload check is `asgard watcher check`, not `asgard help`.
  def test_regression_w16_loki_valid_runs_asgard_watcher_check_in_the_root
    Dir.mktmpdir do |dir|
      good = File.join(dir, "good")
      File.write(good, "#!/bin/sh\n[ \"$1 $2\" = 'watcher check' ] && [ \"$PWD\" = \"#{File.realpath(dir)}\" ]\n")
      File.chmod(0o755, good)
      assert Daemon.loki_valid?(good, File.realpath(dir))
      refute Daemon.loki_valid?("/bin/false", dir)
    end
  end

  def test_regression_w1_next_action
    assert_equal :wait,   Daemon.next_action(stopping: false, reload: false)
    assert_equal :reload, Daemon.next_action(stopping: false, reload: true)
    assert_equal :stop,   Daemon.next_action(stopping: true,  reload: true), "a stop wins over a pending reload"
  end
end

# Drives `asgard watcher ...` end to end in a temp project, with HOME, PATH
# and XDG_STATE_HOME pointed at temp dirs and a fake asgard on PATH that
# records what it was asked to run.
class TestWatchCommands < Minitest::Test
  Commands = Asgard::Watch::Commands

  def setup
    @saved   = ENV.to_h.slice("HOME", "PATH", "XDG_STATE_HOME", "ASGARD_TEST_SECRET")
    @cwd     = Dir.pwd
    @tmp     = File.realpath(Dir.mktmpdir)
    @project = File.join(@tmp, "proj")
    @bin     = File.join(@tmp, "bin")
    FileUtils.mkdir_p [File.join(@project, "lib"), @bin]
    File.write(File.join(@project, ".loki"), "")
    @slug    = Asgard::Schedule.project_slug(@project)
    # As the daemon: sleep until stopped, without exec, so the pid keeps an
    # "asgard watcher run" command line, and take the sleep along when
    # TERM ends it. As a task: record the call.
    File.write(File.join(@bin, "asgard"), <<~SH)
      #!/bin/sh
      if [ "$1" = "watcher" ]; then trap 'kill $!; exit 0' TERM; /bin/sleep 30 & wait; exit; fi
      echo "$* modified=$ASGARD_MODIFIED added=$ASGARD_ADDED" >> "$ASGARD_WATCH_ROOT/ran.txt"
    SH
    File.chmod(0o755, File.join(@bin, "asgard"))
    ENV["HOME"] = @tmp
    ENV["PATH"] = @bin
    ENV["XDG_STATE_HOME"] = File.join(@tmp, "state")
    ENV["ASGARD_TEST_SECRET"] = "leak"
    Asgard::Watch.declarations.clear
    @saved_traps = %w[INT TERM].to_h { |signal| [signal, trap(signal, "DEFAULT")] }
  end

  def teardown
    @saved_traps.each { |signal, handler| trap(signal, handler) }
    Dir.chdir(@cwd)
    pid = state.running_pid
    Process.kill("TERM", pid) if pid && pid != Process.pid # a detached fake daemon, never ourselves
    @saved.each { |key, value| ENV[key] = value }
    ENV.delete("ASGARD_TEST_SECRET") unless @saved.key?("ASGARD_TEST_SECRET")
    Asgard::Watch.declarations.clear
    FileUtils.rm_rf(@tmp)
  end

  # Each call stands for a separate `asgard watcher ...` process.
  def watcher(*argv)
    Commands._reset_ran!
    Dir.chdir(@project) { Commands.start(argv) }
  end

  def state = Asgard::Watch::State.new(project: @slug, root: @project, base: File.join(@tmp, "state", "asgard", "watch"))

  def wait_until(seconds = 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert yield, "condition not met within #{seconds}s"
  end

  def test_describe_and_last_run
    spec = Asgard::Watch.normalize(:tree, paths: %w[lib test], events: %i[added removed])
    assert_equal "lib test [added, removed]", Commands.describe(spec)
    assert_equal "lib/**/*.rb", Commands.describe(Asgard::Watch.normalize(:tree, paths: "lib/**/*.rb"))
    assert_equal "never", Commands.last_run(nil)
    assert_equal "running (pid 41)", Commands.last_run({ pid: 41 }, running: ->(_) { true })
    finished = Time.new(2026, 10, 18, 9, 30, 2).iso8601
    assert_equal "3 (2.5s, 2026-10-18 09:30:02)", Commands.last_run({ pid: 41, finished:, status: 3, seconds: 2.5 })
  end

  # W7: an entry whose task never reported an exit (a crash, a kill -9,
  # a reload) is not "running" once its pid is gone.
  def test_regression_w7_last_run_of_a_dead_unfinished_entry
    assert_equal "running (pid 41)", Commands.last_run({ pid: 41, task: "t" }, running: ->(_) { true })
    assert_equal "did not finish (pid 41)", Commands.last_run({ pid: 41, task: "t" }, running: ->(_) { false })
  end

  def test_asgard_watcher_maps_to_the_subcommand_and_help_hides_the_underscore
    Commands._reset_ran!
    out, = capture_io { Dir.chdir(@project) { Tasks.start(%w[watcher list]) } }
    assert_match "No watches declared for #{@slug}", out
    assert_match "asgard watcher list --all", out
    out, = capture_io { Commands.start(%w[help]) }
    assert_match " watcher start", out
    refute_match(/ _watcher /, out)
    assert Asgard.machine_wide?(%w[watcher list])
    refute Asgard.machine_wide?(%w[watcher start])
  end

  def test_start_and_run_require_declared_known_tasks
    _, err = capture_io { assert_raises(SystemExit) { watcher("start") } }
    assert_match "No watches declared", err
    Tasks.watch :no_such_task, paths: "lib"
    _, err = capture_io { assert_raises(SystemExit) { watcher("run") } }
    assert_match "no such task(s): no_such_task", err
  end

  def test_run_refuses_when_another_daemon_holds_the_pidfile
    Tasks.watch :tree, paths: "lib"
    other = Process.spawn(File.join(@bin, "asgard"), "watcher", "run") # another fake daemon
    state.prepare.write_pid(other)
    _, err = capture_io { assert_raises(SystemExit) { watcher("run") } }
    assert_match "already running for #{@slug} (pid #{other})", err
  ensure
    if other
      Process.kill("TERM", other)
      Process.wait(other)
    end
  end

  def test_a_pidfile_naming_a_stranger_is_not_a_running_daemon
    Tasks.watch :tree, paths: "lib"
    stranger = Process.spawn("/bin/sleep", "30")
    state.prepare.write_pid(stranger)
    assert_nil state.running_pid
    _, err = capture_io { assert_raises(SystemExit) { watcher("stop") } }
    assert_match "not running for #{@slug}", err
    assert Asgard::Watch::Reporter.alive?(stranger), "stop must not signal a process that is not the daemon"
  ensure
    if stranger
      Process.kill("TERM", stranger)
      Process.wait(stranger)
    end
  end

  def test_start_list_stop_round_trip
    Tasks.watch :tree, paths: "lib/**/*.rb"
    out, = capture_io { watcher("start") }
    assert_match(/started watcher for #{@slug} \(pid \d+\)/, out)
    pid = state.running_pid
    assert pid
    assert_equal [{ name: "tree", task: "tree", paths: ["lib/**/*.rb"], events: %w[changed added removed] }], state.read_declarations

    _, err = capture_io { assert_raises(SystemExit) { watcher("start") } }
    assert_match "already running for #{@slug} (pid #{pid})", err

    out, = capture_io { watcher("list") }
    assert_match(/NAME\s+│\s*TASK\s+│\s*WATCHES\s+│\s*DAEMON\s+│\s*LAST RUN/, out)
    assert_match(%r{│ tree\s+│ asgard tree\s+│ lib/\*\*/\*\.rb\s+│ running\s+│ never}, out)
    assert_match(/^Logs: .*asgard watcher log/, out)

    out, = capture_io { watcher("stop") }
    assert_match "stopped watcher for #{@slug}", out
    assert_nil state.running_pid
    refute Asgard::Watch::Reporter.alive?(pid)

    out, = capture_io { watcher("list") }
    assert_match(%r{│ tree\s+│ asgard tree\s+│ lib/\*\*/\*\.rb\s+│ stopped\s+│ never}, out)
    _, err = capture_io { assert_raises(SystemExit) { watcher("stop") } }
    assert_match "not running for #{@slug}", err
  end

  # W6: a second start that checks the pidfile before the first daemon
  # has written it must still be refused. Removing the first daemon's
  # pidfile puts the second start in exactly that position.
  def test_regression_w6_a_second_start_racing_the_first_is_refused
    Tasks.watch :tree, paths: "lib/**/*.rb"
    capture_io { watcher("start") }
    first = state.running_pid
    assert first
    File.delete(state.pid_path)
    _, err = capture_io { assert_raises(SystemExit) { watcher("start") } }
    assert_match "already running for #{@slug}", err
  ensure
    [first, state.read_pid].compact.uniq.each do |pid|
      Process.kill("TERM", pid) if pid.positive? && pid != Process.pid && Asgard::Watch::State.daemon?(pid)
    end
  end

  def test_list_shows_last_runs_and_every_project_with_all
    Tasks.watch :tree, paths: "lib"
    state.prepare.write_entry("tree", { entry: "tree", task: "tree", pid: 1, started: Time.now.iso8601,
                                        finished: Time.new(2026, 10, 18, 9, 30, 2).iso8601, status: 3, seconds: 2.5 })
    other = Asgard::Watch::State.new(project: "elsewhere", root: "/elsewhere", base: File.join(@tmp, "state", "asgard", "watch"))
    other.prepare.write_declarations([Asgard::Watch.normalize(:docs, paths: "docs", events: :added)])
    other.write_entry("docs", { entry: "docs", task: "docs", pid: Process.pid, started: Time.now.iso8601 })

    out, = capture_io { watcher("list") }
    assert_match(/│ tree\s+│ asgard tree\s+│ lib\s+│ stopped\s+│ 3 \(2\.5s, 2026-10-18 09:30:02\)/, out)
    refute_match "elsewhere", out

    out, = capture_io { watcher("list", "--all") }
    assert_equal ["Project: elsewhere (/elsewhere) [root missing]", "Project: #{@slug} (#{@project})"],
                 out.lines.grep(/^Project:/).map(&:chomp)
    assert_match(/│ docs\s+│ asgard docs\s+│ docs \[added\]\s+│ stopped\s+│ running \(pid #{Process.pid}\)/, out)

    File.delete(File.join(@project, ".loki"))
    out, = capture_io { watcher("list") }
    assert_match "Project: elsewhere", out
    FileUtils.rm_rf(File.join(@tmp, "state"))
    out, = capture_io { watcher("list") }
    assert_match "No watchers have been started", out
  end

  def test_preview_shows_argv_and_the_isolated_environment
    Tasks.watch :tree, paths: "lib", env: { BUILD: "dev" }
    out, = capture_io { watcher("preview") }
    assert_match "# tree: #{@bin}/asgard tree  (lib)", out
    assert_match "ASGARD_WATCH=tree", out
    assert_match "ASGARD_WATCH_ROOT=#{@project}", out
    assert_match "BUILD=dev", out
    assert_match "PATH=#{@bin}", out
    refute_match "ASGARD_TEST_SECRET", out
  end

  def test_log_prints_the_log_or_says_there_is_none
    _, err = capture_io { watcher("log") }
    assert_match "no watcher log yet", err
    state.prepare
    File.write(state.log_path, "line one\n")
    out, = capture_io { watcher("log") }
    assert_equal "line one\n", out
  end

  def test_run_watches_for_real_and_runs_the_task_on_a_change
    Tasks.watch :tree, paths: "lib/**/*.rb", debounce: 0.1
    state.prepare.write_pid(Process.pid) # as `start` leaves it for the child: our own pid is not "another daemon"
    Dir.chdir(@project)
    Commands._reset_ran!
    thread = Thread.new { capture_io { Commands.start(["run"]) } }
    wait_until { state.running_pid }
    sleep 1 # let the adapter settle

    File.write(File.join(@project, "lib", "a.rb"), "# change\n")
    ran = File.join(@project, "ran.txt")
    wait_until(15) { File.exist?(ran) }
    assert_equal "tree modified= added=lib/a.rb\n", File.read(ran)
    wait_until { state.read_entry("tree")&.key?(:finished) }
    assert_equal 0, state.read_entry("tree")[:status]

    Process.kill("TERM", Process.pid) # the daemon's own trap stops it
    thread.join
    assert_nil state.read_pid
    assert_includes File.read(state.log_path), "spawn tree"
  ensure
    if thread&.alive?
      Process.kill("TERM", Process.pid)
      thread.join(10)
    end
  end
end

# Identifying the process behind a recorded pid: a pidfile left by a crash
# or a reboot can name a pid that an unrelated process now holds.
class TestWatchProcessIdentity < Minitest::Test
  Reporter = Asgard::Watch::Reporter
  State    = Asgard::Watch::State

  def test_asgard_process_matches_every_word_of_the_command_line
    assert Reporter.asgard_process?(4242, "watcher", "run", command: "ruby /usr/local/bin/asgard watcher run")
    assert Reporter.asgard_process?(4242, "lint", command: "/opt/homebrew/bin/direnv exec /proj /usr/local/bin/asgard lint")
    refute Reporter.asgard_process?(4242, "watcher", "run", command: "/bin/sleep 30")
    refute Reporter.asgard_process?(4242, "watcher", "run", command: "ruby /usr/local/bin/asgard lint")
  end

  def test_the_current_process_always_counts_as_asgard
    assert Reporter.asgard_process?(Process.pid, "anything")
    assert State.daemon?(Process.pid)
    assert State.running?({ pid: Process.pid, task: "docs" })
  end

  def test_command_line_reads_a_live_process_and_is_nil_for_a_dead_one
    stranger = Process.spawn("/bin/sleep", "30")
    assert_includes Reporter.command_line(stranger), "sleep"
    refute State.daemon?(stranger), "a live process that is not asgard is not the daemon"
    refute State.running?({ pid: stranger, task: "docs" })
    Process.kill("TERM", stranger)
    Process.wait(stranger)
    assert_nil Reporter.command_line(stranger)
    refute Reporter.asgard_process?(stranger, "watcher", "run")
  end
end

# The pieces the watcher and background jobs share, tested on their own.
class TestPidAndStateDir < Minitest::Test
  Pid      = Asgard::Pid
  StateDir = Asgard::StateDir

  def test_matches_checks_every_word_against_a_real_child
    child = Process.spawn("/bin/sleep", "30")
    # ps shows the parent's argv until the child has exec'd, so give it a moment.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.02 until Pid.matches?(child, "sleep", "30") || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert Pid.matches?(child, "sleep", "30")
    assert Pid.matches?(child, :sleep), "words may be symbols"
    refute Pid.matches?(child, "sleep", "31")
    refute Pid.matches?(child, "asgard")
    assert Pid.matches?(Process.pid, "anything at all"), "the current process always counts"
    assert Pid.matches?(4242, "x", "y", command: "x and y"), "command: stands in for ps"
    Process.kill("TERM", child)
    Process.wait(child)
    refute Pid.matches?(child, "sleep")
    assert_nil Pid.command_line(child)
    refute Pid.alive?(child)
  end

  # J4: procps can cut the command line to the terminal width, and a
  # job's script path sits at the very end of a long one.
  def test_regression_j4_ps_is_asked_for_unlimited_width
    assert_equal [Pid::PS, "-ww", "-o", "command=", "-p", "42"], Pid.ps_argv(42)
  end

  def test_regression_j4_a_long_command_line_comes_back_whole
    tail  = "x" * 400
    child = Process.spawn(["/bin/sleep", "sleep-#{tail}"], "30")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.02 until Pid.command_line(child).to_s.include?("sleep-") || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    saved = ENV.fetch("COLUMNS", nil)
    ENV["COLUMNS"] = "40"
    assert_includes Pid.command_line(child), tail
  ensure
    saved ? ENV["COLUMNS"] = saved : ENV.delete("COLUMNS")
    if child
      Process.kill("TERM", child)
      Process.wait(child)
    end
  end

  def test_regression_j10_group_commands_keeps_only_that_group
    out = "  501 /bin/sh -c trap asgard-job bash /s/api.sh\n  777 bash /s/api.sh\n  777 sleep 30\n 7770 other\n"
    assert_equal ["bash /s/api.sh", "sleep 30"], Pid.group_commands(out, 777)
    assert_empty Pid.group_commands("", 777)
  end

  def test_all_lists_one_kind_at_a_time
    Dir.mktmpdir do |home|
      watch = StateDir.base_dir("watch", home:, env: {})
      jobs  = StateDir.base_dir("jobs",  home:, env: {})
      assert_equal File.join(home, ".local", "state", "asgard", "jobs"), jobs
      assert_equal "/xdg/asgard/jobs", StateDir.base_dir(:jobs, home:, env: { "XDG_STATE_HOME" => "/xdg" })
      StateDir.record_root(File.join(watch, "a-1"), "/a")
      StateDir.record_root(File.join(jobs, "b-2"), "/b")
      StateDir.record_root(File.join(jobs, "c-3"), "/c")
      assert_equal [["a-1", "/a"]],                 StateDir.all(base: watch)
      assert_equal [["b-2", "/b"], ["c-3", "/c"]], StateDir.all(base: jobs)
      assert_equal [], StateDir.all(base: File.join(home, "none"))
    end
  end

  # X2: logs and job scripts can hold secrets; only the owner may look.
  def test_regression_x2_a_project_state_directory_is_private
    Dir.mktmpdir do |home|
      dir = File.join(home, "asgard", "jobs", "p-1")
      StateDir.record_root(dir, "/p")
      assert_equal 0o700, File.stat(dir).mode & 0o777
    end
  end

  # X3: one corrupt record must not take down a listing.
  def test_regression_x3_a_corrupt_record_reads_as_nil
    Dir.mktmpdir do |home|
      path = File.join(home, "bad.json")
      File.write(path, "{ not json")
      assert_nil StateDir.read_json(path)
      state = Asgard::Jobs::State.new(project: "p", root: "/p", base: home)
      state.prepare
      File.write(File.join(state.dir, "broken.json"), "{")
      state.write_record({ name: "ok", task: "t", pid: 4242, pgid: 4242, started: "2026-10-24T00:00:00Z", script: "/p/ok.sh" })
      assert_equal(["ok"], state.records.map { |record| record[:name] })
    end
  end

  def test_json_round_trip_symbolizes_keys_and_creates_the_directory
    Dir.mktmpdir do |home|
      path = File.join(home, "deep", "er", "record.json")
      assert_nil StateDir.read_json(path)
      StateDir.write_json(path, { "name" => "api", pid: 42 })
      assert_equal({ name: "api", pid: 42 }, StateDir.read_json(path))
      assert_equal ["record.json"], Dir.children(File.dirname(path)), "no tempfile is left behind"
    end
  end
end

# Review round 2 (W17-W30). Each test names the defect it pins.

# W17: an adopted lock is close-on-exec, so a task the daemon spawns (and
# anything that task leaves behind) never holds watcher.lock.
class TestWatchState
  def test_regression_w17_an_adopted_lock_is_not_inherited_by_children
    held = @state.acquire_lock
    held.close_on_exec = false # as it arrives across start's spawn or a reload's exec
    adopted = @state.adopt_lock({ State::LOCK_ENV => held.fileno.to_s })
    held.autoclose = false # adopted owns the descriptor now
    assert_predicate adopted, :close_on_exec?
    child = Process.spawn("/bin/sleep", "30") # a task left running
    adopted.close
    fresh = @state.acquire_lock
    assert fresh, "a leftover child must not keep the watcher locked"
  ensure
    fresh&.close
    if child
      Process.kill("KILL", child)
      Process.wait(child)
    end
  end

  def test_regression_w17_a_fresh_lock_is_close_on_exec
    lock = @state.acquire_lock
    assert_predicate lock, :close_on_exec?
  ensure
    lock&.close
  end
end

# W18: a reload checks what `watcher run` checks, not just that the task
# files load: a renamed task or a removed last watch keeps the old daemon.
class TestWatchCheck < Minitest::Test
  include AsgardProcess

  def loki(*lines) = "class Tasks\n  desc 't', 't'\n  def t = nil\n#{lines.map { |line| "  #{line}\n" }.join}end\n"

  def test_regression_w18_watcher_check_passes_a_runnable_project
    _, err, status = run_asgard(loki("watch :t, paths: 'lib'"), "watcher", "check")
    assert_predicate status, :success?, err
  end

  def test_regression_w18_watcher_check_fails_an_unknown_task_or_no_watches
    _, err, status = run_asgard(loki("watch :renamed, paths: 'lib'"), "watcher", "check")
    refute_predicate status, :success?
    assert_match "no such task(s): renamed", err
    _, err, status = run_asgard(loki, "watcher", "check")
    refute_predicate status, :success?
    assert_match "No watches declared", err
  end
end

# W19: a bad env: is refused when the .loki loads, and a spawn that raises
# something other than a SystemCallError still leaves the worker alive.
class TestWatchDeclaration
  def test_regression_w19_bad_env_is_rejected_at_load
    [{ "A=B" => "x" }, { "A\0" => "x" }, { "A" => "x\0y" }, { 1 => "x" }, { "" => "x" }, "A=1"].each do |env|
      error = assert_raises(ArgumentError, env.inspect) { W.normalize(:t, paths: "lib", env:) }
      assert_match(/\Awatch :t env: /, error.message)
    end
    assert_equal({ "A" => "1", "B" => "" }, W.normalize(:t, paths: "lib", env: { A: 1, "B" => nil })[:env])
  end
end

class TestWatchWorker
  def test_regression_w19_an_argument_error_from_spawn_is_reported_as_127
    queue   = Queue.new
    reports = Queue.new
    spawner = RaisingSpawner.new(ArgumentError.new("environment name contains a equal : A=B"))
    thread  = start_thread(queue, reports, spawner)
    2.times { queue.push(description("lint")) }
    failed = Timeout.timeout(5) { reports.pop }
    assert_equal [:exit, nil, 127], failed.values_at(:kind, :pid, :status)
    assert_match(/contains a equal/, failed[:error])
    spawned = Timeout.timeout(5) { reports.pop }
    assert_equal :spawn, spawned[:kind], "the worker lives on"
    spawner.release(spawned[:pid], 0)
    Timeout.timeout(5) { reports.pop }
  ensure
    queue&.push(nil)
    thread&.join(5)
  end

  def test_regression_w19_a_real_ractor_survives_a_bad_environment
    queue   = RactorQueue.new(capacity: 16)
    reports = RactorQueue.new(capacity: 16)
    inbox   = Asgard::Watch::Mailbox.new(queue, Worker.start(queue, reports))
    inbox.push(description("bad", env: { "A=B" => "x" }))
    inbox.push(description("ok"))
    inbox.push(nil)
    received = Array.new(3) { reports.pop(timeout: 10) }
    assert_equal(%i[exit spawn exit], received.map { |report| report[:kind] })
    assert_equal 127, received[0][:status]
  end
end

# W20: each directory of a declaration matches only its own patterns.
class TestWatchDeclaration
  def test_regression_w20_each_directory_matches_only_its_own_patterns
    spec = W.normalize(:t, paths: %w[lib/*.rb test/*_test.rb])
    assert_equal %w[lib test], spec[:dirs]
    assert_match spec[:only]["test"], "a_test.rb"
    refute_match spec[:only]["test"], "helper.rb"
    assert_match spec[:only]["lib"], "foo.rb"
    spec = W.normalize(:t, paths: %w[lib/*.rb config/app.yml])
    refute_match spec[:only]["lib"], "app.yml"
    assert_match spec[:only]["config"], "app.yml"
    refute_match spec[:only]["config"], "x.rb"
  end

  def test_regression_w20_only_still_narrows_every_directory
    spec = W.normalize(:t, paths: %w[lib/**/* test/**/*], only: /\.rb\z/)
    assert_match spec[:only]["test"], "a/b.rb"
    refute_match spec[:only]["test"], "a/b.md"
  end

  def test_regression_w20_a_nested_directory_folds_into_its_parent
    spec = W.normalize(:t, paths: %w[**/*.rb lib/*.yml])
    assert_equal ["."], spec[:dirs]
    ["x.rb", "a/b.rb", "lib/c.yml"].each { |path| assert_match spec[:only]["."], path }
    ["lib/sub/c.yml", "c.yml"].each { |path| refute_match spec[:only]["."], path }
    assert_equal ["lib"], W.normalize(:t, paths: %w[lib lib/asgard])[:dirs]
  end
end

# W25 / W29: default ignores prune directory scans, and the project's own
# output directories are ignored at the project root only.
class TestWatchDeclaration
  def test_regression_w25_default_ignores_match_a_bare_directory
    ignored = ->(path) { W::DEFAULT_IGNORES.any? { |regexp| regexp.match?(path) } }
    assert ignored.call("node_modules")
    assert ignored.call("app/node_modules")
    assert ignored.call(".git")
    refute ignored.call("node_modules_backup")
  end

  def test_regression_w29_root_ignores_apply_to_the_project_root_only
    assert_equal [*W::DEFAULT_IGNORES, *W::ROOT_IGNORES], W.ignores_for(".", [])
    assert_equal [/x/, *W::DEFAULT_IGNORES], W.ignores_for("app", [/x/])
  end
end

class TestWatchDaemon
  def silencer(spec, dir)
    require "listen"
    Listen::Silencer.new(**Daemon.listen_options(spec, dir).slice(:only, :ignore!))
  end

  def test_regression_w25_listen_skips_ignored_directories_while_scanning
    root = silencer(Asgard::Watch.normalize(:t, paths: "**/*.rb"), ".")
    %w[node_modules app/node_modules coverage log tmp .git].each { |dir| assert root.silenced?(dir, :dir), dir }
    refute root.silenced?("app/log", :dir), "a log/ below the root is the user's own"
    refute root.silenced?("app/coverage", :dir)
    assert root.silenced?("lib/.a.rb.swp", :file), "editor temp files stay ignored"
    app = silencer(Asgard::Watch.normalize(:t, paths: "app/**/*"), "app")
    refute app.silenced?("log", :dir), "app/log under an app/ watch"
    refute app.silenced?("log/x.rb", :file)
    assert app.silenced?("node_modules", :dir)
  end

  def test_regression_w20_the_daemon_listens_once_per_directory
    spec    = Asgard::Watch.normalize(:lint, paths: %w[lib/*.rb test/*_test.rb], debounce: 0.1)
    watcher = daemon({ "lint" => spec }, tasks: %w[lint])
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }
    lib, test, = @listen.listeners
    assert_equal [["lib"], ["test"]], [lib.dirs, test.dirs]
    refute_match test.options[:only], "helper.rb"
    assert_match test.options[:only], "x_test.rb"
  ensure
    watcher&.stop
    thread&.join(10)
  end

  # W21: a second INT or TERM ends running tasks: TERM to each task's
  # process group, then KILL once the grace period passes.
  def test_regression_w21_a_second_stop_kills_the_running_task
    watcher = daemon(declarations, grace: 0.5)
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }
    @listen.listeners.first.callback.call(["lib/a.rb"], [], [])
    wait_until { @state.read_entry("lint")&.key?(:pid) }
    pid = @state.read_entry("lint")[:pid]
    watcher.stop
    sleep 0.3
    assert thread.alive?, "the first stop waits"
    watcher.stop
    assert thread.join(10), "the second stop ends the task"
    refute Asgard::Pid.alive?(pid)
    assert_equal 143, @state.read_entry("lint")[:status]
    assert_match "killing", @out.string
  ensure
    FileUtils.touch(File.join(@root, "go"))
    thread&.join(10)
  end

  def test_regression_w21_a_task_that_ignores_term_is_killed_after_the_grace
    File.write(@asgard, "#!/bin/sh\ntrap '' TERM\nwhile :; do /bin/sleep 0.05; done\n")
    watcher = daemon(declarations, grace: 0.5)
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }
    @listen.listeners.first.callback.call(["lib/a.rb"], [], [])
    wait_until { @state.read_entry("lint")&.key?(:pid) }
    2.times { watcher.stop }
    assert thread.join(10)
    assert_equal 137, @state.read_entry("lint")[:status]
  ensure
    thread&.join(10)
  end

  # Records what would be signalled; nothing here ever reaches kill(2).
  def kills = @kills ||= []
  def recorder = ->(signal, target) { kills << [signal, target] }

  def test_regression_w21_signal_task_refuses_anything_but_our_own_task_group
    probes = { own_pgrp: 500, pgid_of: ->(pid) { pid }, command: ->(_) { "/bin/asgard lint" }, kill: recorder }
    [nil, "77", 0, 1, -5, 500, Process.pid].each do |pid|
      refute Daemon.signal_task("KILL", pid, "lint", **probes), pid.inspect
    end
    refute Daemon.signal_task("KILL", 77, "lint", **probes, pgid_of: ->(_) { 1 }), "not the leader of its own group"
    refute Daemon.signal_task("KILL", 77, "docs", **probes), "a different task"
    refute Daemon.signal_task("KILL", 77, "lint", **probes, command: ->(_) { "/bin/sleep lint" }), "not asgard"
    refute Daemon.signal_task("KILL", 77, "lint", **probes, pgid_of: ->(_) { raise Errno::ESRCH }), "gone"
    assert_empty kills
    assert Daemon.signal_task("TERM", 77, "lint", **probes)
    assert_equal [["TERM", -77]], kills
  end

  def test_regression_w21_signal_task_ends_a_real_task_group
    pid = Process.spawn(@asgard, "lint", pgroup: true, chdir: @root, out: File::NULL)
    wait_until { Asgard::Pid.command_line(pid).to_s.include?("lint") }
    assert Daemon.signal_task("TERM", pid, "lint")
    _, status = Process.wait2(pid)
    assert_equal 15, status.termsig
    pid = nil
  ensure
    if pid
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end

  # W22: changes saved while a reload waits for running tasks reach the
  # new daemon instead of being lost.
  def test_regression_w22_changes_during_a_reload_are_handed_to_the_next_daemon
    watcher = daemon(declarations)
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }
    lint = @listen.listeners.first
    lint.callback.call(["lib/a.rb"], [], [])
    wait_until { @state.read_entry("lint")&.key?(:pid) }
    @listen.listeners.last.callback.call([".loki"], [], []) # reload, behind the running lint
    sleep 0.4
    lint.callback.call(["lib/b.rb"], [], [])
    FileUtils.touch(File.join(@root, "go"))
    wait_until { @execs.any? }
    env  = @execs.first.first
    path = env[Asgard::Watch::State::PENDING_ENV]
    assert_equal @state.pending_path, path
    assert_equal [{ entry: "lint", changes: { modified: ["lib/b.rb"], added: [], removed: [] } }], Asgard::Watch::State.read_json(path)
  ensure
    FileUtils.touch(File.join(@root, "go"))
    thread&.join(10)
  end

  def test_regression_w22_a_reloaded_daemon_replays_the_pending_changes
    FileUtils.touch(File.join(@root, "go"))
    pending = File.join(@tmp, "pending.json")
    Asgard::Watch::State.write_json(pending, [{ entry: "lint", changes: { modified: ["lib/b.rb"], added: [], removed: [] } },
                                              { entry: "gone", changes: { modified: ["x"], added: [], removed: [] } }])
    watcher = daemon(declarations, config: { pending: })
    thread  = Thread.new { watcher.run }
    wait_until { @state.read_entry("lint")&.key?(:finished) }
    assert_includes File.read(@state.log_path), "trigger lint task=lint lib/b.rb"
    refute File.exist?(pending), "used once"
  ensure
    watcher&.stop
    thread&.join(10)
  end

  # W23: "watcher: reloading" is written out before exec replaces the
  # process, even when the output is a buffered file.
  def test_regression_w23_the_reloading_line_is_flushed_before_exec
    path = File.join(@tmp, "daemon.out")
    seen = []
    File.open(path, "w") do |out|
      watcher = daemon(declarations, out:, exec: ->(*) { seen << File.read(path) })
      thread  = Thread.new { watcher.run }
      wait_until { @state.running_pid }
      @listen.listeners.last.callback.call([".loki"], [], [])
      wait_until { seen.any? }
      assert_includes seen.first, "watcher: reloading"
    ensure
      watcher&.stop
      thread&.join(10)
    end
  end

  # W24: the daemon's own output follows the log through rotation.
  def test_regression_w24_daemon_output_is_reopened_on_the_new_log
    log = File.join(@tmp, "w.log")
    File.open(log, "a") do |out|
      assert Daemon.writes_to?(out, log)
      refute Daemon.writes_to?(StringIO.new, log)
      File.rename(log, "#{log}.1")
      refute Daemon.writes_to?(out, log)
      Daemon.reopen_log([out], log)
      out.puts "after"
      assert_equal "after\n", File.read(log)
    end
  end

  # W26: every daemon run, a reload included, records its declarations.
  def test_regression_w26_run_records_the_declarations
    watcher = daemon(declarations)
    thread  = Thread.new { watcher.run }
    wait_until { @state.running_pid }
    assert_equal(%w[lint docs], @state.read_declarations.map { |record| record[:name] })
  ensure
    watcher&.stop
    thread&.join(10)
  end

  # W27: triggers dropped at shutdown take their spill files with them.
  def test_regression_w27_close_queue_deletes_the_spill_files_it_drops
    spill = File.join(@tmp, "c.json")
    File.write(spill, "{}")
    queue = RactorQueue.new(capacity: 4)
    queue.push(Ractor.make_shareable({ entry: "lint", changes_file: spill, changes: { modified: ["a"], added: [], removed: [] } }))
    queue.push(Ractor.make_shareable({ entry: "docs", changes: { modified: [], added: ["b"], removed: [] } }))
    dropped = Daemon.close_queue(Asgard::Watch::Mailbox.new(queue, nil))
    refute File.exist?(spill)
    assert_equal(%w[lint docs], dropped.map { |item| item[:entry] })
    assert_nil queue.pop(timeout: 1), "the closing nil"
  end
end

# W21: `watcher stop --force` sends a second TERM, which the daemon
# takes as "kill the running tasks".
class TestWatchCommands
  def test_regression_w21_stop_force_sends_a_second_term
    File.write(File.join(@bin, "asgard"), <<~SH)
      #!/bin/sh
      n=0
      trap 'n=$((n+1)); [ $n -ge 2 ] && exit 0' TERM
      while :; do /bin/sleep 0.1; done
    SH
    Tasks.watch :tree, paths: "lib"
    capture_io { watcher("start") }
    wait_until { state.running_pid }
    pid = state.running_pid
    out, = capture_io { Timeout.timeout(15) { watcher("stop", "--force") } }
    assert_match "stopped watcher for #{@slug}", out
    refute Asgard::Watch::State.daemon?(pid)
  ensure
    Process.kill("KILL", pid) if pid && Asgard::Watch::State.daemon?(pid)
  end

  # W24: `log -f` follows the log across rotation.
  def test_regression_w24_log_follow_survives_rotation
    assert_equal "tail -n +1 -F /s/watcher.log", Commands.follow_command("/s/watcher.log")
  end
end

# W24: the reporter says when it rotated, so the daemon can follow.
# W28: a failed spawn is its own record, not the previous run's.
class TestWatchReporter
  def test_regression_w24_the_reporter_announces_a_rotation
    rotated  = []
    reporter = Reporter.new(@queue, log: @log, state: @state, max_log: 200, on_rotate: -> { rotated << true })
    File.write(@log, "x" * 250)
    reporter.handle(trigger)
    reporter.handle(trigger)
    assert_equal [true], rotated
  end

  def test_regression_w28_a_failed_spawn_does_not_inherit_the_previous_run
    previous = Reporter.entry_record(exit_report(41), Reporter.entry_record(spawn(41)))
    failed   = Reporter.entry_record({ kind: :exit, entry: "lint", task: "lint", pid: nil, at: AT + 9, status: 127,
                                       seconds: 0.0, error: "No such file" }, previous)
    assert_nil failed[:pid]
    refute failed.key?(:started)
    assert_equal [127, "No such file", Time.at(AT + 9).iso8601], failed.values_at(:status, :error, :finished)
  end
end

# W29: character classes, nested braces, dotfiles that do not exist yet,
# ./ prefixes, and paths holding a newline.
class TestWatchDeclaration
  def test_regression_w29_character_classes
    regexp = W.glob_regexp("[ab].rb")
    assert_match regexp, "a.rb"
    refute_match regexp, "c.rb"
    refute_match regexp, "[ab].rb"
    negated = W.glob_regexp("[!a]x")
    assert_match negated, "bx"
    refute_match negated, "ax"
    refute_match negated, "/x"
    assert_match W.glob_regexp("[a-c]"), "b"
    assert_match W.glob_regexp("[x"), "[x", "an unclosed bracket is literal"
    assert_equal "lib", W.split_glob("lib/[ab].rb").first
  end

  def test_regression_w29_nested_braces
    regexp = W.glob_regexp("{a,{b,c}}.rb")
    %w[a.rb b.rb c.rb].each { |path| assert_match regexp, path }
    ["d.rb", "{b.rb"].each { |path| refute_match regexp, path }
    assert_match W.glob_regexp("{x,y{1,2}}"), "y2"
  end

  def test_regression_w29_a_missing_dotfile_is_a_file
    assert_equal [".", /\A\.env\z/],         W.split_glob(".env", stat: NOT_FILE)
    assert_equal ["config", /\A\.secrets\z/], W.split_glob("config/.secrets", stat: NOT_FILE)
    assert_equal "lib", W.split_glob("./lib/*.rb").first
  end
end

class TestRegressionChangesFile
  def test_regression_w29_a_path_holding_a_newline_travels_in_the_file
    changes = Asgard::Changes.new(modified: ["odd\nname.rb"])
    assert_equal({ "ASGARD_CHANGES_FILE" => "/c.json" }, Spawn.change_env(changes, "/c.json"))
    assert_equal changes.to_env, Spawn.change_env(changes, nil), "no file to use: keep the env"
    plain = Asgard::Changes.new(modified: ["plain.rb"])
    assert_equal plain.to_env, Spawn.change_env(plain, "/c.json")
  end
end

# W30: the Ruby version managers' variables reach the task.
class TestWatchSpawn
  def test_regression_w30_base_env_keeps_version_manager_variables
    env = { "RUBY_ROOT" => "/r", "RUBY_ENGINE" => "ruby", "RUBY_VERSION" => "4.0.0", "RBENV_VERSION" => "4.0.0",
            "GEM_ROOT" => "/g", "RUBYOPT" => "-W0", "SECRET" => "x" }
    assert_equal env.keys - ["SECRET"], S.base_env(env).keys
  end
end
