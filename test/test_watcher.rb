# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "ractor_queue"
require "stringio"

class TestWatchDeclaration < Minitest::Test
  W = Asgard::Watch

  # Stand-ins for File in split_glob: every plain path is / is not a file.
  IS_FILE  = Module.new { def self.file?(_path) = true }
  NOT_FILE = Module.new { def self.file?(_path) = false }

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
    assert_match spec[:only], "asgard/base.rb"
    refute_match spec[:only], "asgard/base.md"
    assert_equal Set[:changed, :added, :removed], spec[:events]
    assert_in_delta 0.5, spec[:debounce]
    assert_empty spec[:env]
    assert_equal W::DEFAULT_IGNORES, spec[:ignore]
  end

  def test_normalize_directories_with_only_ignore_env_and_as
    spec = W.normalize(:test, paths: %w[lib test], only: /\.rb\z/, ignore: %r{\Afixtures/}, env: { BUILD: :dev }, as: "unit")
    assert_equal "unit",       spec[:name]
    assert_equal "test",       spec[:task]
    assert_equal %w[lib test], spec[:dirs]
    assert_equal(/\.rb\z/, spec[:only])
    assert_equal [%r{\Afixtures/}, *W::DEFAULT_IGNORES], spec[:ignore]
    assert_equal({ "BUILD" => "dev" }, spec[:env])
    assert_nil W.normalize(:t, paths: "lib")[:only]
  end

  def test_normalize_dedups_dirs_and_accepts_any_pattern
    spec = W.normalize(:t, paths: %w[lib/**/*.rb lib/**/*.erb])
    assert_equal ["lib"], spec[:dirs]
    assert_match spec[:only], "a/b.rb"
    assert_match spec[:only], "a/b.erb"
    refute_match spec[:only], "a/b.md"
  end

  def test_normalize_requires_both_pattern_and_only_when_both_given
    spec = W.normalize(:t, paths: "lib/**/*", only: /\.rb\z/)
    assert_match spec[:only], "a/b.rb"
    refute_match spec[:only], "a/b.md"
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
    assert ignored.call("coverage/index.html")
    assert ignored.call("sub/tmp/x")
    assert ignored.call(".git/HEAD")
    refute ignored.call("lib/tmpfile.rb")
    refute ignored.call("mylog/x")
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
    Worker.start(queue, reports)
    queue.push(description("ok"))
    queue.push(description("bad", "sh", "-c", "echo hi; exit 3"))
    queue.push(nil)

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

  def test_drain_waits_for_the_exit_report
    @reporter.handle(spawn(41))
    thread = @reporter.start
    Thread.new do
      sleep 0.05
      @queue.push(exit_report(41))
      @queue.push(nil)
    end
    out = StringIO.new
    @reporter.drain(interval: 0.01, out: out)
    assert_empty @reporter.running
    assert_includes out.string, "waiting for pid 41"
  ensure
    thread&.join
  end

  def test_drain_forgets_a_pid_that_is_gone
    dead = Process.spawn("true")
    Process.wait(dead)
    @reporter.handle(spawn(dead))
    @reporter.handle(spawn(Process.pid, "me"))
    helper = Thread.new do
      sleep 0.05
      @reporter.handle(exit_report(Process.pid, 0, "me"))
    end
    @reporter.drain(interval: 0.01, out: StringIO.new)
    assert_empty @reporter.running
    refute Reporter.alive?(dead)
    assert Reporter.alive?(Process.pid)
  ensure
    helper&.join
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
    assert_equal 2, @dispatcher.workers["lint"][:queue].size
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

  def test_declarations_round_trip
    specs = [Asgard::Watch.normalize(:lint, paths: "lib/**/*.rb", events: :added)]
    assert_empty @state.read_declarations
    @state.write_declarations(specs)
    assert_equal [{ name: "lint", task: "lint", paths: ["lib/**/*.rb"], events: ["added"] }], @state.read_declarations
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

  def daemon(declarations, tasks: %w[lint docs])
    config = Daemon::Config.new(declarations:, root: @root, state: @state, context: @context, tasks:)
    Daemon.new(config, listen: @listen, exec: ->(*argv) { @execs << argv }, out: @out)
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
    assert_equal({ only: /\.md\z/, ignore: Asgard::Watch::DEFAULT_IGNORES, wait_for_delay: 0.5, relative: true },
                 Daemon.listen_options(declarations["docs"]))
    refute_includes Daemon.listen_options(Asgard::Watch.normalize(:t, paths: "lib")).keys, :only
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
    assert_equal(/\.loki\z/, loki.options[:only])
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
    assert_equal [[@asgard, "watcher", "run"]], @execs
    refute @listen.listeners.any?(&:started)
  ensure
    watcher&.stop
    thread&.join
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
    # As the daemon: sleep until stopped. As a task: record the call.
    File.write(File.join(@bin, "asgard"), <<~SH)
      #!/bin/sh
      if [ "$1" = "watcher" ]; then exec /bin/sleep 30; fi
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

  def state = Asgard::Watch::State.new(project: "proj", root: @project, base: File.join(@tmp, "state", "asgard", "watch"))

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
    assert_equal "running (pid 41)", Commands.last_run({ pid: 41 })
    finished = Time.new(2026, 10, 18, 9, 30, 2).iso8601
    assert_equal "3 (2.5s, 2026-10-18 09:30:02)", Commands.last_run({ pid: 41, finished:, status: 3, seconds: 2.5 })
  end

  def test_asgard_watcher_maps_to_the_subcommand_and_help_hides_the_underscore
    Commands._reset_ran!
    out, = capture_io { Dir.chdir(@project) { Tasks.start(%w[watcher list]) } }
    assert_match "No watches declared for proj", out
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
    other = Process.spawn("/bin/sleep", "30") # PATH holds only the fake bin here
    state.prepare.write_pid(other)
    _, err = capture_io { assert_raises(SystemExit) { watcher("run") } }
    assert_match "already running for proj (pid #{other})", err
  ensure
    if other
      Process.kill("TERM", other)
      Process.wait(other)
    end
  end

  def test_start_list_stop_round_trip
    Tasks.watch :tree, paths: "lib/**/*.rb"
    out, = capture_io { watcher("start") }
    assert_match(/started watcher for proj \(pid \d+\)/, out)
    pid = state.running_pid
    assert pid
    assert_equal [{ name: "tree", task: "tree", paths: ["lib/**/*.rb"], events: %w[changed added removed] }], state.read_declarations

    _, err = capture_io { assert_raises(SystemExit) { watcher("start") } }
    assert_match "already running for proj (pid #{pid})", err

    out, = capture_io { watcher("list") }
    assert_match(/NAME\s+│\s*TASK\s+│\s*WATCHES\s+│\s*DAEMON\s+│\s*LAST RUN/, out)
    assert_match(%r{│ tree\s+│ asgard tree\s+│ lib/\*\*/\*\.rb\s+│ running\s+│ never}, out)
    assert_match(/^Logs: .*asgard watcher log/, out)

    out, = capture_io { watcher("stop") }
    assert_match "stopped watcher for proj", out
    assert_nil state.running_pid
    refute Asgard::Watch::Reporter.alive?(pid)

    out, = capture_io { watcher("list") }
    assert_match(%r{│ tree\s+│ asgard tree\s+│ lib/\*\*/\*\.rb\s+│ stopped\s+│ never}, out)
    _, err = capture_io { assert_raises(SystemExit) { watcher("stop") } }
    assert_match "not running for proj", err
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
    assert_equal ["Project: elsewhere (/elsewhere)", "Project: proj (#{@project})"], out.lines.grep(/^Project:/).map(&:chomp)
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
