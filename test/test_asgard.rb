# frozen_string_literal: true

require "test_helper"
require "tempfile"

class TestAsgardVersion < Minitest::Test
  def test_version_is_defined
    refute_nil Asgard::VERSION
  end
end

class TestAsgardLoadLoki < Minitest::Test
  def test_loads_star_loki_files
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, "zebra.loki"),
                 "class Tasks; desc 'zebra', 'z'; def zebra_task = nil; end")
      File.write(File.join(dir, "alpha.loki"),
                 "class Tasks; desc 'alpha', 'a'; def alpha_task = nil; end")
      Asgard.load_loki(dir)
      assert Tasks.method_defined?(:alpha_task)
      assert Tasks.method_defined?(:zebra_task)
    end
  ensure
    Tasks.class_eval { %i[alpha_task zebra_task].each { |m| remove_method(m) rescue nil } }
    Tasks._reset_ran!
  end

  def test_ignores_dot_loki_file
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"),
                 "class Tasks; no_commands { def dot_loki_sentinel = nil }; end")
      Asgard.load_loki(dir)
      refute Tasks.method_defined?(:dot_loki_sentinel)
    end
  end

  def test_does_nothing_when_no_star_loki_files_exist
    Dir.mktmpdir do |dir|
      Asgard.load_loki(File.realpath(dir))
    end
  end
end

class TestAsgardRun < Minitest::Test
  def test_run_exits_when_no_loki_file_found
    Dir.mktmpdir do |dir|
      _, err = capture_io do
        assert_raises(SystemExit) { Dir.chdir(dir) { Asgard.run!([]) } }
      end
      assert_match "no .loki file found", err
    end
  end

  def test_run_catches_circular_dep_in_non_tasks_subclass
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), <<~RUBY)
        class SubGroup < Asgard::Base
          depends_on :sub_b
          desc "sub_a", "a"; def sub_a = nil
          depends_on :sub_a
          desc "sub_b", "b"; def sub_b = nil
        end
      RUBY
      _, err = capture_io do
        assert_raises(SystemExit) { Dir.chdir(dir) { Asgard.run!([]) } }
      end
      assert_match "circular dependency", err
    end
  ensure
    Object.send(:remove_const, :SubGroup) if Object.const_defined?(:SubGroup)
    Tasks._reset_ran!
  end

  def test_run_catches_undefined_dep_in_non_tasks_subclass
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), <<~RUBY)
        class SubGroup2 < Asgard::Base
          depends_on :ghost
          desc "sub_a", "a"; def sub_a = nil
        end
      RUBY
      _, err = capture_io do
        assert_raises(SystemExit) { Dir.chdir(dir) { Asgard.run!([]) } }
      end
      assert_match "undefined task", err
    end
  ensure
    Object.send(:remove_const, :SubGroup2) if Object.const_defined?(:SubGroup2)
    Tasks._reset_ran!
  end

  def test_run_detects_orphaned_depends_on
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), "class Tasks\n  depends_on :build\nend\n")
      _, err = capture_io do
        assert_raises(SystemExit) { Dir.chdir(dir) { Asgard.run!([]) } }
      end
      assert_match "depends_on", err
    end
  ensure
    Tasks.instance_variable_set(:@_pending_deps, [])
    Tasks._reset_ran!
  end

  def test_run_exits_on_circular_dependency
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), <<~RUBY)
        class Tasks
          depends_on :circ_b
          desc "circ_a", "a"
          def circ_a = nil

          depends_on :circ_a
          desc "circ_b", "b"
          def circ_b = nil
        end
      RUBY
      _, err = capture_io do
        assert_raises(SystemExit) { Dir.chdir(dir) { Asgard.run!([]) } }
      end
      assert_match "circular dependency", err
    end
  ensure
    Tasks._deps.delete(:circ_a)
    Tasks._deps.delete(:circ_b)
    Tasks.class_eval { %i[circ_a circ_b].each { |m| remove_method(m) rescue nil } }
    Tasks._reset_ran!
  end
end

class TestAsgardTasks < Minitest::Test
  def test_tasks_is_defined
    assert defined?(Tasks), "Tasks should be defined by the gem"
  end

  def test_tasks_inherits_from_base
    assert Tasks < Asgard::Base
  end

  def test_tasks_can_be_reopened_with_new_methods
    log = []
    Tasks.class_eval do
      desc "test_reopen", "reopened method"
      define_method(:test_reopen) { log << :ran }
    end
    Tasks.new([], {}, {}).invoke(:test_reopen)
    assert_includes log, :ran
  ensure
    Tasks.class_eval { remove_method(:test_reopen) rescue nil }
    Tasks._reset_ran!
  end
end

class TestAsgardFindFile < Minitest::Test
  def test_returns_nil_when_not_found
    Dir.chdir("/tmp") do
      assert_nil Asgard.find_task_file
    end
  end

  def test_finds_dot_loki_in_current_directory
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, ".loki")
      File.write(path, "")
      result = Dir.chdir(dir) { Asgard.find_task_file }
      assert_equal path, result
    end
  end

  def test_finds_dot_loki_in_parent_directory
    Dir.mktmpdir do |dir|
      dir    = File.realpath(dir)
      path   = File.join(dir, ".loki")
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      File.write(path, "")
      result = Dir.chdir(subdir) { Asgard.find_task_file }
      assert_equal path, result
    end
  end

  def test_ignores_star_loki_files
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, "tasks.loki"), "")
      result = Dir.chdir(dir) { Asgard.find_task_file }
      assert_nil result
    end
  end
end

class TestAsgardVar < Minitest::Test
  def setup
    @klass = Class.new(Asgard::Base) do
      var :greeting, "hello"
      var :dynamic,  -> { "dyn_42" }
    end
  end

  def test_static_var_returns_value
    assert_equal "hello", @klass.new([], {}, {}).greeting
  end

  def test_dynamic_var_is_evaluated_lazily
    assert_equal "dyn_42", @klass.new([], {}, {}).dynamic
  end

  def test_var_with_block
    klass = Class.new(Asgard::Base) do
      var(:computed) { "block_val" }
    end
    assert_equal "block_val", klass.new([], {}, {}).computed
  end

  def test_var_lambda_is_memoized
    call_count = 0
    klass = Class.new(Asgard::Base) do
      var :expensive, lambda {
        call_count += 1
        "result"
      }
    end
    instance = klass.new([], {}, {})
    3.times { instance.expensive }
    assert_equal 1, call_count
  end

  def test_var_memoization_is_per_instance
    klass = Class.new(Asgard::Base) do
      var :counter, -> { Object.new }
    end
    a = klass.new([], {}, {})
    b = klass.new([], {}, {})
    assert_same a.counter, a.counter
    refute_same a.counter, b.counter
  end
end

class TestAsgardDependsOn < Minitest::Test
  def setup
    @log = []
    log  = @log

    @klass = Class.new(Asgard::Base) do
      desc "build", "compile"
      define_method(:build) { log << :build }

      depends_on :build
      desc "test", "run tests"
      define_method(:test) { log << :test }

      depends_on :test
      desc "release", "publish"
      define_method(:release) { log << :release }
    end
  end

  def test_deps_stored_as_stages
    assert_equal [[:build]], @klass._deps[:test]
  end

  def test_dep_runs_before_method
    @klass.new([], {}, {}).invoke(:test)
    assert_equal %i[build test], @log
  end

  def test_transitive_deps_run_in_order
    @klass.new([], {}, {}).invoke(:release)
    assert_equal %i[build test release], @log
  end

  def test_dep_runs_only_once
    instance = @klass.new([], {}, {})
    instance.invoke(:build)
    instance.invoke(:test)
    assert_equal %i[build test], @log, "build should not run a second time"
  end

  def test_method_added_ignores_underscore_prefix
    klass = Class.new(Asgard::Base) do
      depends_on :build
      no_commands { define_method(:_private_helper) {} }
    end
    refute klass._deps.key?(:_private_helper)
  end

  def test_depends_on_survives_no_commands_block_between_declaration_and_task
    log   = []
    klass = Class.new(Asgard::Base) do
      desc "build", "build"
      define_method(:build) { log << :build }

      depends_on :build
      no_commands { define_method(:helper) {} }
      desc "test", "run tests"
      define_method(:test) { log << :test }
    end
    klass.new([], {}, {}).invoke(:test)
    assert_equal %i[build test], log
  end

  def test_depends_on_survives_var_declaration_between_declaration_and_task
    log   = []
    klass = Class.new(Asgard::Base) do
      desc "build", "build"
      define_method(:build) { log << :build }

      depends_on :build
      var :gem_name, "asgard"
      desc "test", "run tests"
      define_method(:test) { log << :test }
    end
    klass.new([], {}, {}).invoke(:test)
    assert_equal %i[build test], log
  end
end

class TestAsgardParallelDeps < Minitest::Test
  def test_parallel_deps_both_run_before_target
    log   = []
    mutex = Mutex.new

    klass = Class.new(Asgard::Base) do
      desc "build", "build"
      define_method(:build) { mutex.synchronize { log << :build } }

      desc "lint", "lint"
      define_method(:lint)  { mutex.synchronize { log << :lint } }

      depends_on %i[build lint]
      desc "test", "test"
      define_method(:test)  { mutex.synchronize { log << :test } }
    end

    klass.new([], {}, {}).invoke(:test)

    assert_includes log[0..1], :build
    assert_includes log[0..1], :lint
    assert_equal    :test,     log.last
  end

  def test_mixed_sequential_and_parallel
    log   = []
    mutex = Mutex.new

    klass = Class.new(Asgard::Base) do
      desc "setup",  "setup"
      define_method(:setup)  { mutex.synchronize { log << :setup } }
      desc "build",  "build"
      define_method(:build)  { mutex.synchronize { log << :build } }
      desc "lint",   "lint"
      define_method(:lint)   { mutex.synchronize { log << :lint } }
      desc "deploy", "deploy"
      define_method(:deploy) { mutex.synchronize { log << :deploy } }

      depends_on :setup, %i[build lint], :deploy
      desc "ci", "ci"
      define_method(:ci) { mutex.synchronize { log << :ci } }
    end

    klass.new([], {}, {}).invoke(:ci)

    assert_equal :setup,  log.first
    assert_includes log[1..2], :build
    assert_includes log[1..2], :lint
    assert_equal :deploy, log[3]
    assert_equal :ci,     log.last
  end

  def test_stages_stored_correctly
    klass = Class.new(Asgard::Base) do
      desc "a", "a"
      define_method(:a) {}
      desc "b", "b"
      define_method(:b) {}
      desc "c", "c"
      define_method(:c) {}
      desc "d", "d"
      define_method(:d) {}

      depends_on :a, %i[b c], :d
      desc "target", "target"
      define_method(:target) {}
    end

    assert_equal [[:a], %i[b c], [:d]], klass._deps[:target]
  end

  def test_all_parallel_dep_threads_joined_before_exception_propagates
    completed = []
    mu        = Mutex.new
    klass     = Class.new(Asgard::Base) do
      desc "raiser", "raiser"
      define_method(:raiser) { raise "boom" }

      desc "slow", "slow"
      define_method(:slow) do
        sleep 0.05
        mu.synchronize { completed << :slow }
      end

      depends_on %i[raiser slow]
      desc "target", "target"
      define_method(:target) {}
    end

    assert_raises(RuntimeError) { klass.new([], {}, {}).invoke(:target) }
    assert_includes completed, :slow
  end
end

class TestAsgardSubclasses < Minitest::Test
  def test_subclass_is_registered
    before = Asgard::Base.subclasses.dup
    klass  = Class.new(Asgard::Base)
    assert_includes Asgard::Base.subclasses - before, klass
  end
end

class TestAsgardCircularDep < Minitest::Test
  def test_raises_on_circular_dependency
    klass = Class.new(Asgard::Base) do
      desc "a", "a"
      define_method(:a) {}
      desc "b", "b"
      define_method(:b) {}
    end

    klass._deps[:a] = [[:b]]
    klass._deps[:b] = [[:a]]

    assert_raises(Asgard::CircularDependencyError) { klass.validate_deps! }
  end

  def test_no_error_when_deps_are_valid
    klass = Class.new(Asgard::Base) do
      desc "a", "a"
      define_method(:a) {}
      depends_on :a
      desc "b", "b"
      define_method(:b) {}
    end
    klass.validate_deps!
  end

  def test_no_error_when_no_deps
    klass = Class.new(Asgard::Base)
    klass.validate_deps!
  end

  def test_raises_on_undefined_dependency_name
    klass = Class.new(Asgard::Base) do
      desc "test", "test"
      define_method(:test) {}
    end
    klass._deps[:test] = [[:nonexistent_task]]
    err = assert_raises(Asgard::Error) { klass.validate_deps! }
    assert_match "nonexistent_task", err.message
  end

  def test_raises_on_multiple_undefined_dependencies
    klass = Class.new(Asgard::Base) do
      desc "test", "test"
      define_method(:test) {}
    end
    klass._deps[:test] = [%i[ghost_a ghost_b]]
    err = assert_raises(Asgard::Error) { klass.validate_deps! }
    assert_match "ghost_a", err.message
    assert_match "ghost_b", err.message
  end

  def test_validate_deps_raises_for_dep_with_required_argument
    klass = Class.new(Asgard::Base) do
      desc "build NAME", "build something"
      def build(name) = nil
      depends_on :build
      desc "test", "test"
      define_method(:test) {}
    end
    err = assert_raises(Asgard::Error) { klass.validate_deps! }
    assert_match "build", err.message
  end

  def test_validate_deps_raises_for_orphaned_pending_dep
    klass = Class.new(Asgard::Base)
    klass.instance_variable_set(:@_pending_deps, [:build])
    err = assert_raises(Asgard::Error) { klass.validate_deps! }
    assert_match "build", err.message
  end
end

class TestAsgardResetRan < Minitest::Test
  def test_reset_ran_clears_execution_tracking
    log   = []
    klass = Class.new(Asgard::Base) do
      desc "build", "build"
      define_method(:build) { log << :build }
    end

    klass.new([], {}, {}).invoke(:build)
    assert_equal 1, log.size

    klass._reset_ran!
    klass.new([], {}, {}).invoke(:build)
    assert_equal 2, log.size
  end
end

class TestAsgardDotenv < Minitest::Test
  def test_dotenv_loads_env_file
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".env"), "ASGARD_TEST_VAR=loaded\n")
      klass = Class.new(Asgard::Base)
      Dir.chdir(dir) { klass.dotenv }
      assert_equal "loaded", ENV.fetch("ASGARD_TEST_VAR", nil)
    end
  ensure
    ENV.delete("ASGARD_TEST_VAR")
  end

  def test_dotenv_silently_skips_missing_file
    klass = Class.new(Asgard::Base)
    klass.dotenv("/nonexistent/path/.env")
  end
end

class TestAsgardRunSuccess < Minitest::Test
  def test_run_executes_task_via_start
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), <<~RUBY)
        class Tasks
          desc "ks_hello", "test task"
          def ks_hello = puts "ks_hello_ran"
        end
      RUBY
      out, = capture_io { Dir.chdir(dir) { Asgard.run!(["ks_hello"]) } }
      assert_match "ks_hello_ran", out
    end
  ensure
    Tasks.class_eval { remove_method(:ks_hello) rescue nil }
    Tasks._reset_ran!
  end

  def test_star_loki_files_not_loaded_without_auto_load_flag
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), "")
      File.write(File.join(dir, "extra.loki"),
                 "class Tasks; desc 'extra_task', 'extra'; def extra_task = nil; end")
      Dir.chdir(dir) { Asgard.run!(["help"]) rescue nil }
      refute Tasks.method_defined?(:extra_task),
             "extra.loki should not be loaded without --auto-load"
    end
  ensure
    Tasks.class_eval { remove_method(:extra_task) rescue nil }
    Tasks._reset_ran!
  end

  def test_star_loki_files_loaded_with_auto_load_flag
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), "")
      File.write(File.join(dir, "extra2.loki"),
                 "class Tasks; desc 'extra2_task', 'extra2'; def extra2_task = nil; end")
      Dir.chdir(dir) { Asgard.run!(["--auto-load", "help"]) rescue nil }
      assert Tasks.method_defined?(:extra2_task),
             "extra2.loki should be loaded when --auto-load is passed"
    end
  ensure
    Tasks.class_eval { remove_method(:extra2_task) rescue nil }
    Tasks._reset_ran!
  end
end

class TestAsgardUnderscoreGuard < Minitest::Test
  def test_run_blocks_underscore_prefixed_commands
    _, err = capture_io do
      assert_raises(SystemExit) { Asgard.run!(["_secret"]) }
    end
    assert_match "unknown command '_secret'", err
  end

  def test_run_does_not_block_double_dash_commands
    # --version starts with '-', not '_', so the guard must not fire
    out, = capture_io do
      assert_raises(SystemExit) { Asgard.run!(["--version"]) }
    end
    assert_equal Asgard::VERSION, out.chomp
  end
end

class TestAsgardBuiltinTasks < Minitest::Test
  def test_version_task_prints_version_and_exits
    out, = capture_io do
      assert_raises(SystemExit) { Tasks.new([], {}, {})._version }
    end
    assert_equal Asgard::VERSION, out.chomp
  end

  def test_tasks_has_debug_class_option
    assert Tasks.class_options.key?(:debug)
  end

  def test_tasks_has_verbose_class_option
    assert Tasks.class_options.key?(:verbose)
  end
end

class TestAsgardDebugVerboseOptions < Minitest::Test
  def setup
    @orig_debug   = $DEBUG
    @orig_verbose = $VERBOSE
  end

  def teardown
    $DEBUG   = @orig_debug
    $VERBOSE = @orig_verbose
  end

  def test_debug_option_sets_global_debug
    klass = Class.new(Asgard::Base) do
      desc "noop", "no-op"
      define_method(:noop) {}
    end
    $DEBUG = false
    klass.new([], { debug: true }, {}).invoke(:noop)
    assert $DEBUG
  end

  def test_verbose_option_sets_global_verbose
    klass = Class.new(Asgard::Base) do
      desc "noop", "no-op"
      define_method(:noop) {}
    end
    $VERBOSE = false
    klass.new([], { verbose: true }, {}).invoke(:noop)
    assert $VERBOSE
  end

  def test_debug_predicate_reflects_global_debug
    $DEBUG = true
    assert Tasks.new([], {}, {}).send(:debug?)
    $DEBUG = false
    refute Tasks.new([], {}, {}).send(:debug?)
  end

  def test_verbose_predicate_reflects_global_verbose
    $VERBOSE = true
    assert Tasks.new([], {}, {}).send(:verbose?)
    $VERBOSE = false
    refute Tasks.new([], {}, {}).send(:verbose?)
  end
end

class TestAsgardDescShorthand < Minitest::Test
  def test_single_arg_desc_uses_method_name_as_usage
    klass = Class.new(Asgard::Base) do
      desc "Run the tests"
      define_method(:test_task) {}
    end
    cmd = klass.all_commands["test_task"]
    assert_equal "test_task",      cmd.usage
    assert_equal "Run the tests",  cmd.description
  end

  def test_single_arg_desc_with_depends_on
    log = []
    klass = Class.new(Asgard::Base) do
      desc "Build step"
      define_method(:build) { log << :build }

      depends_on :build
      desc "Run tests"
      define_method(:test) { log << :test }
    end
    klass.new([], {}, {}).invoke(:test)
    assert_equal %i[build test], log
  end

  def test_two_arg_desc_still_works
    klass = Class.new(Asgard::Base) do
      desc "custom_usage NAME", "explicit description"
      define_method(:my_task) {}
    end
    cmd = klass.all_commands["my_task"]
    assert_equal "custom_usage NAME",    cmd.usage
    assert_equal "explicit description", cmd.description
  end

  def test_single_arg_desc_survives_var_between_desc_and_method
    klass = Class.new(Asgard::Base) do
      desc "Run tests"
      var :gem_name, "asgard"
      define_method(:test) {}
    end
    cmd = klass.all_commands["test"]
    assert_equal "test",       cmd.usage
    assert_equal "Run tests",  cmd.description
  end

  def test_single_arg_desc_survives_no_commands_block_between_desc_and_method
    klass = Class.new(Asgard::Base) do
      desc "Run tests"
      no_commands { define_method(:helper) {} }
      define_method(:test) {}
    end
    cmd = klass.all_commands["test"]
    assert_equal "test",       cmd.usage
    assert_equal "Run tests",  cmd.description
  end

  def test_single_arg_desc_preserves_options
    klass = Class.new(Asgard::Base) do
      desc "Hidden task", hide: true
      define_method(:secret) {}
    end
    assert klass.all_commands["secret"].hidden?
  end
end

class TestAsgardShell < Minitest::Test
  include Asgard::Shell

  def test_sh_single_line_runs_command
    f = Tempfile.new("asgard_sh_test")
    sh "echo single > #{f.path}", silent: true
    assert_equal "single\n", File.read(f.path)
  ensure
    f.unlink
  end

  def test_sh_multiline_runs_all_lines
    f = Tempfile.new("asgard_sh_multi")
    sh <<~SHELL, silent: true
      echo first > #{f.path}
      echo second >> #{f.path}
    SHELL
    assert_equal "first\nsecond\n", File.read(f.path)
  ensure
    f.unlink
  end

  def test_sh_silent_suppresses_command_echo
    out, = capture_io { sh "echo quiet", silent: true }
    assert_empty out
  end

  def test_sh_prints_command_when_not_silent
    out, = capture_io { sh "echo loud" }
    assert_match "echo loud", out
  end

  def test_sh_exits_on_failure
    assert_raises(SystemExit) { sh "exit 1", silent: true }
  end

  def test_shebang_runs_ruby_script
    f = Tempfile.new("asgard_shebang_test")
    shebang :ruby, "File.write('#{f.path}', 'from_ruby')", silent: true
    assert_equal "from_ruby", File.read(f.path)
  ensure
    f.unlink
  end

  def test_shebang_silent_suppresses_script_echo
    f = Tempfile.new("asgard_shebang_silent")
    out, = capture_io { shebang :ruby, "File.write('#{f.path}', 'x')", silent: true }
    assert_empty out
  ensure
    f.unlink
  end

  def test_shebang_prints_script_when_not_silent
    f = Tempfile.new("asgard_shebang_loud")
    out, = capture_io { shebang :ruby, "File.write('#{f.path}', 'x')" }
    assert_match "File.write", out
  ensure
    f.unlink
  end

  def test_shebang_exits_on_failure
    assert_raises(SystemExit) { shebang :ruby, "exit 1", silent: true }
  end

  def test_shebang_uses_tmp_extension_for_unknown_interpreter
    assert_raises(SystemExit) do
      shebang :nonexistent_interpreter_xyz, "echo hi", silent: true
    end
  end
end
