# frozen_string_literal: true

require "test_helper"
require "tempfile"

class TestAsgardVersion < Minitest::Test
  def test_version_is_defined
    refute_nil Asgard::VERSION
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

class TestLokiUp < Minitest::Test
  def test_returns_nil_when_not_found
    Dir.chdir("/tmp") do
      assert_nil loki_up("nonexistent_sentinel_xyzzy.loki")
    end
  end

  def test_finds_default_dot_loki_in_current_directory
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, ".loki")
      File.write(path, "")
      result = Dir.chdir(dir) { loki_up }
      assert_equal path, result
    end
  end

  def test_finds_default_dot_loki_in_parent_directory
    Dir.mktmpdir do |dir|
      dir    = File.realpath(dir)
      path   = File.join(dir, ".loki")
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      File.write(path, "")
      result = Dir.chdir(subdir) { loki_up }
      assert_equal path, result
    end
  end

  def test_finds_named_file_in_current_directory
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "gem_tasks.loki")
      File.write(path, "")
      result = Dir.chdir(dir) { loki_up("gem_tasks.loki") }
      assert_equal path, result
    end
  end

  def test_finds_named_file_in_parent_directory
    Dir.mktmpdir do |dir|
      dir    = File.realpath(dir)
      path   = File.join(dir, "gem_tasks.loki")
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      File.write(path, "")
      result = Dir.chdir(subdir) { loki_up("gem_tasks.loki") }
      assert_equal path, result
    end
  end

  def test_returns_nil_when_named_file_not_found
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), "")
      result = Dir.chdir(dir) { loki_up("gem_tasks.loki") }
      assert_nil result
    end
  end

  def test_nearest_match_wins
    Dir.mktmpdir do |dir|
      dir    = File.realpath(dir)
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      File.write(File.join(dir,    "gem_tasks.loki"), "")
      File.write(File.join(subdir, "gem_tasks.loki"), "")
      result = Dir.chdir(subdir) { loki_up("gem_tasks.loki") }
      assert_equal File.join(subdir, "gem_tasks.loki"), result
    end
  end

  def test_available_as_kernel_module_method
    assert_respond_to Kernel, :loki_up
  end
end

class TestImport < Minitest::Test
  def setup
    @orig_debug   = $DEBUG
    @orig_verbose = $VERBOSE
    $DEBUG   = false
    $VERBOSE = false
  end

  def teardown
    $DEBUG   = @orig_debug
    $VERBOSE = @orig_verbose
  end

  def test_raises_for_non_loki_extension
    err = assert_raises(ArgumentError) { import("/tmp/tasks.rb") }
    assert_match ".loki", err.message
  end

  def test_raises_for_no_extension
    assert_raises(ArgumentError) { import("/tmp/tasks") }
  end

  def test_accepts_pathname
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "gem_tasks.loki")
      File.write(path, "")
      assert import(Pathname.new(path))
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("gem_tasks.loki") }
  end

  def test_loads_loki_file_by_absolute_path
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "shared.loki")
      File.write(path, "IMPORT_SHARED_LOADED = true")
      import(path)
      assert Object.const_get(:IMPORT_SHARED_LOADED)
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("shared.loki") }
    Object.send(:remove_const, :IMPORT_SHARED_LOADED) rescue nil
  end

  def test_returns_false_when_already_loaded
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "once.loki")
      File.write(path, "")
      import(path)
      assert_equal false, import(path)
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("once.loki") }
  end

  def test_glob_loads_all_matching_files
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, "alpha.loki"), "IMPORT_GLOB_ALPHA = true")
      File.write(File.join(dir, "beta.loki"),  "IMPORT_GLOB_BETA  = true")
      assert import(File.join(dir, "*.loki"))
      assert Object.const_get(:IMPORT_GLOB_ALPHA)
      assert Object.const_get(:IMPORT_GLOB_BETA)
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f =~ /alpha\.loki|beta\.loki/ }
    %i[IMPORT_GLOB_ALPHA IMPORT_GLOB_BETA].each { |c| Object.send(:remove_const, c) rescue nil }
  end

  def test_glob_loads_in_alphabetical_order
    Object.const_set(:IMPORT_ORDER_LOG, [])
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, "z_tasks.loki"), "IMPORT_ORDER_LOG << :z")
      File.write(File.join(dir, "a_tasks.loki"), "IMPORT_ORDER_LOG << :a")
      import(File.join(dir, "*.loki"))
      assert_equal %i[a z], IMPORT_ORDER_LOG
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f =~ /[az]_tasks\.loki/ }
    Object.send(:remove_const, :IMPORT_ORDER_LOG) rescue nil
  end

  def test_glob_excludes_dot_loki_dotfile
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"),       "IMPORT_GLOB_DOTFILE  = true")
      File.write(File.join(dir, "named.loki"),  "IMPORT_GLOB_NAMED    = true")
      import(File.join(dir, "*.loki"))
      refute Object.const_defined?(:IMPORT_GLOB_DOTFILE)
      assert Object.const_get(:IMPORT_GLOB_NAMED)
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f =~ /\.loki$/ }
    %i[IMPORT_GLOB_DOTFILE IMPORT_GLOB_NAMED].each { |c| Object.send(:remove_const, c) rescue nil }
  end

  def test_glob_returns_false_when_no_files_match
    Dir.mktmpdir do |dir|
      assert_equal false, import(File.join(File.realpath(dir), "*.loki"))
    end
  end

  def test_glob_is_idempotent
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, "once.loki"), "")
      import(File.join(dir, "*.loki"))
      assert_equal false, import(File.join(dir, "*.loki"))
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("once.loki") }
  end

  def test_verbose_prints_path_to_stderr
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "verbose.loki")
      File.write(path, "")
      _, err = capture_io do
        $VERBOSE = true
        import(path)
      end
      assert_match path, err
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("verbose.loki") }
  end

  def test_debug_prints_path_to_stderr
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "debugged.loki")
      File.write(path, "")
      _, err = capture_io do
        $DEBUG = true
        import(path)
      end
      assert_match path, err
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("debugged.loki") }
  end

  def test_debug_prints_skip_message_for_already_loaded_file
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "skip_me.loki")
      File.write(path, "")
      import(path)
      _, err = capture_io do
        $DEBUG = true
        import(path)
      end
      assert_match "already loaded", err
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("skip_me.loki") }
  end

  def test_no_output_when_neither_verbose_nor_debug
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "quiet.loki")
      File.write(path, "")
      out, err = capture_io { import(path) }
      assert_empty out
      assert_empty err
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("quiet.loki") }
  end

  def test_available_as_kernel_module_method
    assert_respond_to Kernel, :import
  end
end

class TestImportUp < Minitest::Test
  def setup
    @orig_debug   = $DEBUG
    @orig_verbose = $VERBOSE
    $DEBUG   = false
    $VERBOSE = false
  end

  def teardown
    $DEBUG   = @orig_debug
    $VERBOSE = @orig_verbose
  end

  def test_returns_false_when_file_not_found
    Dir.chdir("/tmp") do
      assert_equal false, import_up("nonexistent_xyzzy.loki")
    end
  end

  def test_loads_named_loki_file_found_up_the_tree
    Dir.mktmpdir do |dir|
      dir    = File.realpath(dir)
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      path = File.join(dir, "gem_tasks.loki")
      File.write(path, "IMPORT_UP_GEM_TASKS_LOADED = true")
      Dir.chdir(subdir) { import_up("gem_tasks.loki") }
      assert Object.const_get(:IMPORT_UP_GEM_TASKS_LOADED)
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("gem_tasks.loki") }
    Object.send(:remove_const, :IMPORT_UP_GEM_TASKS_LOADED) rescue nil
  end

  def test_loads_default_dot_loki
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, ".loki")
      File.write(path, "IMPORT_UP_DOT_LOKI_LOADED = true")
      Dir.chdir(dir) { import_up }
      assert Object.const_get(:IMPORT_UP_DOT_LOKI_LOADED)
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?(".loki") }
    Object.send(:remove_const, :IMPORT_UP_DOT_LOKI_LOADED) rescue nil
  end

  def test_is_idempotent
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "idempotent.loki")
      File.write(path, "")
      Dir.chdir(dir) { import_up("idempotent.loki") }
      Dir.chdir(dir) { assert_equal false, import_up("idempotent.loki") }
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("idempotent.loki") }
  end

  def test_glob_loads_matching_files_in_first_ancestor_with_matches
    Dir.mktmpdir do |dir|
      dir    = File.realpath(dir)
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      File.write(File.join(dir, "shared.loki"), "IMPORT_UP_GLOB_SHARED = true")
      Dir.chdir(subdir) { import_up("*.loki") }
      assert Object.const_get(:IMPORT_UP_GLOB_SHARED)
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("shared.loki") }
    Object.send(:remove_const, :IMPORT_UP_GLOB_SHARED) rescue nil
  end

  def test_glob_stops_at_first_ancestor_with_matches
    Dir.mktmpdir do |dir|
      dir    = File.realpath(dir)
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      File.write(File.join(dir,    "root.loki"),  "IMPORT_UP_GLOB_ROOT  = true")
      File.write(File.join(subdir, "local.loki"), "IMPORT_UP_GLOB_LOCAL = true")
      Dir.chdir(subdir) { import_up("*.loki") }
      assert  Object.const_defined?(:IMPORT_UP_GLOB_LOCAL)
      refute  Object.const_defined?(:IMPORT_UP_GLOB_ROOT)
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f =~ /root\.loki|local\.loki/ }
    %i[IMPORT_UP_GLOB_ROOT IMPORT_UP_GLOB_LOCAL].each { |c| Object.send(:remove_const, c) rescue nil }
  end

  def test_glob_returns_false_when_no_ancestor_has_matches
    Dir.mktmpdir do |dir|
      dir    = File.realpath(dir)
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      result = Dir.chdir(subdir) { import_up("*.loki") }
      assert_equal false, result
    end
  end

  def test_verbose_prints_found_path_to_stderr
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "found.loki")
      File.write(path, "")
      _, err = capture_io do
        $VERBOSE = true
        Dir.chdir(dir) { import_up("found.loki") }
      end
      assert_match "found.loki", err
      assert_match path, err
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("found.loki") }
  end

  def test_debug_prints_not_found_to_stderr
    Dir.chdir("/tmp") do
      _, err = capture_io do
        $DEBUG = true
        import_up("missing_xyzzy.loki")
      end
      assert_match "not found", err
    end
  end

  def test_no_output_when_neither_verbose_nor_debug
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "silent.loki")
      File.write(path, "")
      out, err = capture_io { Dir.chdir(dir) { import_up("silent.loki") } }
      assert_empty out
      assert_empty err
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("silent.loki") }
  end

  def test_available_as_kernel_module_method
    assert_respond_to Kernel, :import_up
  end
end

class TestKernelPredicates < Minitest::Test
  def setup
    @orig_debug   = $DEBUG
    @orig_verbose = $VERBOSE
  end

  def teardown
    $DEBUG   = @orig_debug
    $VERBOSE = @orig_verbose
  end

  def test_debug_predicate_reflects_global
    $DEBUG = true
    assert debug?
    $DEBUG = false
    refute debug?
  end

  def test_verbose_predicate_reflects_global
    $VERBOSE = true
    assert verbose?
    $VERBOSE = false
    refute verbose?
  end

  def test_debug_available_as_kernel_module_method
    assert_respond_to Kernel, :debug?
  end

  def test_verbose_available_as_kernel_module_method
    assert_respond_to Kernel, :verbose?
  end
end

class TestKernelEnv < Minitest::Test
  def setup
    @orig = ENV.to_h
  end

  def teardown
    ENV.replace(@orig)
  end

  def test_symbol_name_is_upcased
    ENV["ASGARD_TEST_PORT"] = "4000"
    assert_equal "4000", env(:asgard_test_port)
  end

  def test_string_name_is_upcased
    ENV["ASGARD_TEST_APP"] = "myapp"
    assert_equal "myapp", env("asgard_test_app")
  end

  def test_already_uppercase_string_works
    ENV["ASGARD_TEST_APP"] = "myapp"
    assert_equal "myapp", env("ASGARD_TEST_APP")
  end

  def test_returns_default_when_missing
    ENV.delete("ASGARD_TEST_MISSING")
    assert_equal "fallback", env(:asgard_test_missing, "fallback")
  end

  def test_raises_key_error_when_missing_and_no_default
    ENV.delete("ASGARD_TEST_MISSING")
    assert_raises(KeyError) { env(:asgard_test_missing) }
  end

  def test_available_as_kernel_module_method
    assert_respond_to Kernel, :env
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

  def test_star_loki_files_loaded_when_dot_loki_calls_import
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, "extra3.loki"),
                 "class Tasks; desc 'extra3_task', 'extra3'; def extra3_task = nil; end")
      File.write(File.join(dir, ".loki"), "import '#{File.join(dir, "*.loki")}'")
      Dir.chdir(dir) { Asgard.run!(["help"]) rescue nil }
      assert Tasks.method_defined?(:extra3_task),
             "extra3.loki should be loaded when .loki calls import"
    end
  ensure
    Tasks.class_eval { remove_method(:extra3_task) rescue nil }
    Tasks._reset_ran!
    $LOADED_FEATURES.delete_if { |f| f.end_with?("extra3.loki") }
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
