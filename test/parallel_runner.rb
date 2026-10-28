# frozen_string_literal: true

# Runs the whole suite in forked worker processes:
#
#   ruby -Ilib:test test/parallel_runner.rb [--workers N] [-v]
#
# The parent loads every test file once, then forks the workers, so each
# starts with the suite already loaded. Workers ask for one test at a time
# over a pipe and send back its Minitest::Result; the parent reports them
# with Minitest's own reporters. Tests go out slowest first, using the times
# saved in tmp/test_times.json by the previous run (new tests go first).
#
# Separate processes, not threads: the tests chdir, set ENV and swap
# $stdout, all of which are process-wide.
#
# Coverage: each worker stores its SimpleCov result under its own command
# name; the parent's normal SimpleCov exit merges them and enforces the
# minimum once.

require "etc"
require "fileutils"
require "json"
require "minitest"
require "optparse"

# The tests must not also run through autorun's at_exit in the parent.
Minitest.class_variable_set(:@@installed_at_exit, true) # rubocop:disable Style/ClassVars -- Minitest's flag

class ParallelRunner
  TIMES_FILE = "tmp/test_times.json"

  def initialize(workers:, verbose: false, io: $stdout)
    @workers = workers
    @verbose = verbose
    @io      = io
  end

  def self.parse(argv)
    options = { workers: [Etc.nprocessors, 8].min, verbose: false }
    OptionParser.new do |o|
      o.on("-w", "--workers N", Integer, "worker processes (default #{options[:workers]})") { options[:workers] = it }
      o.on("-v", "--verbose", "print each test's name and time") { options[:verbose] = true }
    end.parse!(argv)
    options
  end

  # Loads the suite, runs it and returns true when every test passed.
  def run(files)
    Minitest.seed ||= (ENV["SEED"] || srand).to_i % 0xFFFF
    files.each { |f| require File.expand_path(f) }
    clear_stale_coverage
    tests    = order(all_tests, load_times)
    reporter = build_reporter
    reporter.start
    results  = dispatch(tests, reporter)
    reporter.report
    save_times(results)
    reporter.passed?
  end

  # [[klass, method_name], ...] for every runnable test.
  def all_tests
    Minitest::Runnable.runnables.flat_map do |klass|
      klass.runnable_methods.map { |name| [klass, name] }
    end
  end

  # +tests+ slowest first by +times+ ("Class#method" => seconds); a test
  # with no recorded time goes first, since nothing says it is quick.
  def order(tests, times)
    tests.sort_by { |klass, name| -times.fetch("#{klass}##{name}", Float::INFINITY) }
  end

  def load_times
    JSON.parse(File.read(TIMES_FILE))
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end

  def save_times(results)
    File.write(TIMES_FILE, JSON.pretty_generate(results.to_h { |r| ["#{r.klass}##{r.name}", r.time.round(4)] }))
  rescue SystemCallError
    nil
  end

  private

  def build_reporter
    options = { io: @io, seed: Minitest.seed, verbose: @verbose, args: "--workers #{@workers}" }
    Minitest::CompositeReporter.new.tap do |reporter|
      reporter << Minitest::SummaryReporter.new(@io, options)
      reporter << Minitest::ProgressReporter.new(@io, options)
    end
  end

  # Hands out +tests+ to the workers one at a time and records each result
  # as it comes back. Returns the results.
  def dispatch(tests, reporter)
    queue    = tests.each_index.to_a
    workers  = Array.new([@workers, tests.size].min) { |n| spawn_worker(n, tests) }
    results  = []
    workers.each { |w| feed(w, queue) }

    until (live = workers.reject { |w| w[:done] }).empty?
      IO.select(live.map { |w| w[:from] })[0].each do |io|
        worker = live.find { |w| w[:from] == io }
        result = receive(io)
        if result
          reporter.prerecord(tests[worker[:current]].first, result.name)
          reporter.record(result)
          results << result
          feed(worker, queue)
        else
          lost(worker, tests, reporter)
        end
      end
    end

    workers.each { |w| Process.wait(w[:pid]) }
    results
  end

  # Sends +worker+ the next test, or closes its input when none are left.
  def feed(worker, queue)
    worker[:current] = queue.shift
    if worker[:current]
      worker[:to].puts(worker[:current])
    else
      worker[:to].close
      worker[:done] = true
    end
  end

  # A worker died with a test in hand: report it as an error and retire it.
  def lost(worker, tests, reporter)
    worker[:done] = true
    worker[:to].close unless worker[:to].closed?
    return unless worker[:current]

    klass, name = tests[worker[:current]]
    reporter.prerecord(klass, name)
    reporter.record(crash_result(klass, name))
  end

  def crash_result(klass, name)
    error = RuntimeError.new("worker process died while running this test")
    error.set_backtrace([])
    test = klass.new(name)
    test.time = 0.0
    test.failures << Minitest::UnexpectedError.new(error)
    Minitest::Result.from(test)
  end

  def spawn_worker(number, tests)
    to_child_r, to_child_w     = IO.pipe
    from_child_r, from_child_w = IO.pipe
    others = (@pipes ||= [])

    pid = fork do
      others.each(&:close)
      to_child_w.close
      from_child_r.close
      work(number, tests, to_child_r, from_child_w)
    end

    to_child_r.close
    from_child_w.close
    others.push(to_child_w, from_child_r)
    { pid: pid, to: to_child_w, from: from_child_r, done: false, current: nil }
  end

  # The worker loop: read a test index, run it, send back its result.
  def work(number, tests, input, output)
    while (line = input.gets)
      klass, name = tests.fetch(line.to_i)
      send_result(output, klass.new(name).run)
    end
    store_coverage(number)
    exit!(0)
  end

  def send_result(io, result)
    data = Marshal.dump(result)
    io.write([data.bytesize].pack("N"), data)
    io.flush
  end

  # The next Minitest::Result from a worker, or nil when it has gone.
  def receive(io)
    size = io.read(4)&.unpack1("N")
    size && Marshal.load(io.read(size)) # rubocop:disable Security/MarshalLoad
  end

  # Each worker stores its own coverage; the parent's SimpleCov exit merges
  # them. Without a fresh resultset, earlier runs would be merged in too.
  def clear_stale_coverage
    return unless defined?(SimpleCov)

    FileUtils.rm_f(SimpleCov::ResultMerger.resultset_path)
  end

  def store_coverage(number)
    return unless defined?(SimpleCov) && SimpleCov.running

    SimpleCov.command_name "parallel worker #{number}"
    SimpleCov.result
  end
end

if $PROGRAM_NAME == __FILE__
  options = ParallelRunner.parse(ARGV)
  passed  = ParallelRunner.new(**options).run(Dir["test/test_*.rb"])
  exit passed
end
