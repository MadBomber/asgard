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
    assert_equal %w[/bin/asgard lint],                  S.argv(spec, context)
    assert_equal %w[/bin/direnv exec /proj asgard lint], S.argv(spec, context(direnv: "/bin/direnv"))
  end

  def test_description_is_complete_and_shareable
    description = S.description(spec, changes, context(direnv: "/bin/direnv"))
    assert Ractor.shareable?(description)
    assert_equal "lint-lib", description[:entry]
    assert_equal "lint",     description[:task]
    assert_equal %w[/bin/direnv exec /proj asgard lint], description[:argv]
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
