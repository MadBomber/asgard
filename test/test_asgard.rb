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

  def test_version_flag_works_without_loki_file
    Dir.mktmpdir do |dir|
      out, _err = capture_io do
        assert_raises(SystemExit) { Dir.chdir(dir) { Asgard.run!(["--version"]) } }
      end
      assert_equal Asgard::VERSION, out.chomp
    end
  end

  def test_doctor_flag_works_without_loki_file
    Dir.mktmpdir do |dir|
      out, _err = capture_io do
        assert_raises(SystemExit) { Dir.chdir(dir) { Asgard.run!(["--doctor"]) } }
      end
      assert_match "no .loki file found", out
    end
  end

  def test_doctor_flag_reports_clean_tree
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), "")
      out, _err = capture_io do
        assert_raises(SystemExit) { Dir.chdir(dir) { Asgard.run!(["--doctor"]) } }
      end
      assert_match "No problems found", out
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

class TestAsgardExitOnFailure < Minitest::Test
  def klass
    Class.new(Asgard::Base) do
      desc "greet NAME", "Greet NAME"
      define_method(:greet) { |name| name }
    end
  end

  def test_missing_argument_exits_nonzero
    _, err = capture_io do
      error = assert_raises(SystemExit) { klass.start(["greet"]) }
      refute error.success?
    end
    assert_match "was called with no arguments", err
  end

  def test_unknown_command_exits_nonzero
    _, err = capture_io do
      error = assert_raises(SystemExit) { klass.start(["nope"]) }
      refute error.success?
    end
    assert_match "Could not find command", err
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
      assert_equal Pathname.new(path), result
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
      assert_equal Pathname.new(path), result
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
      assert_equal Pathname.new(path), result
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
      assert_equal Pathname.new(path), result
    end
  end

  def test_finds_named_file_in_current_directory
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, "gem_tasks.loki")
      File.write(path, "")
      result = Dir.chdir(dir) { loki_up("gem_tasks.loki") }
      assert_equal Pathname.new(path), result
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
      assert_equal Pathname.new(path), result
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
      assert_equal Pathname.new(File.join(subdir, "gem_tasks.loki")), result
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

class TestAsgardDependsOnProc < Minitest::Test
  def test_proc_dep_is_stored_unresolved_until_validate_deps
    klass = Class.new(Asgard::Base) do
      desc "build", "compile"
      define_method(:build) {}

      depends_on -> { [[:build]] }
      desc "test", "run tests"
      define_method(:test) {}
    end

    assert_respond_to klass._deps[:test], :call
    klass.validate_deps!
    assert_equal [[:build]], klass._deps[:test]
  end

  def test_proc_dep_runs_before_method
    log = []
    klass = Class.new(Asgard::Base) do
      desc "build", "compile"
      define_method(:build) { log << :build }

      depends_on -> { [[:build]] }
      desc "test", "run tests"
      define_method(:test) { log << :test }
    end

    klass.validate_deps!
    klass.new([], {}, {}).invoke(:test)
    assert_equal %i[build test], log
  end

  def test_proc_dep_body_runs_with_class_as_self
    klass = Class.new(Asgard::Base) do
      desc "a_check", "a"
      define_method(:a_check) {}

      desc "b_check", "b"
      define_method(:b_check) {}

      depends_on -> { [all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)] }
      desc "quality", "aggregate"
      define_method(:quality) {}
    end

    klass.validate_deps!
    assert_equal [%i[a_check b_check]], klass._deps[:quality]
  end

  def test_proc_dep_error_is_wrapped_in_asgard_error
    klass = Class.new(Asgard::Base) do
      depends_on -> { raise "boom" }
      desc "test", "run tests"
      define_method(:test) {}
    end

    error = assert_raises(Asgard::Error) { klass.validate_deps! }
    assert_match "depends_on proc for 'test' raised RuntimeError: boom", error.message
  end

  def test_proc_dep_still_detects_undefined_task
    klass = Class.new(Asgard::Base) do
      depends_on -> { [[:ghost]] }
      desc "test", "run tests"
      define_method(:test) {}
    end

    error = assert_raises(Asgard::Error) { klass.validate_deps! }
    assert_match "undefined task(s) in depends_on: ghost", error.message
  end
end

class TestAsgardDependsOnBlock < Minitest::Test
  def test_block_dep_is_stored_unresolved_until_validate_deps
    klass = Class.new(Asgard::Base) do
      desc "build", "compile"
      define_method(:build) {}

      depends_on { [[:build]] }
      desc "test", "run tests"
      define_method(:test) {}
    end

    assert_respond_to klass._deps[:test], :call
    klass.validate_deps!
    assert_equal [[:build]], klass._deps[:test]
  end

  def test_block_dep_runs_before_method
    log = []
    klass = Class.new(Asgard::Base) do
      desc "build", "compile"
      define_method(:build) { log << :build }

      depends_on { [[:build]] }
      desc "test", "run tests"
      define_method(:test) { log << :test }
    end

    klass.validate_deps!
    klass.new([], {}, {}).invoke(:test)
    assert_equal %i[build test], log
  end

  def test_block_dep_body_runs_with_class_as_self
    klass = Class.new(Asgard::Base) do
      desc "a_check", "a"
      define_method(:a_check) {}

      desc "b_check", "b"
      define_method(:b_check) {}

      depends_on { [all_commands.keys.grep(/_check\z/).sort.map(&:to_sym)] }
      desc "quality", "aggregate"
      define_method(:quality) {}
    end

    klass.validate_deps!
    assert_equal [%i[a_check b_check]], klass._deps[:quality]
  end

  def test_depends_on_rejects_tasks_and_block_together
    error = assert_raises(Asgard::Error) do
      Class.new(Asgard::Base) do
        depends_on(:build) { [[:build]] }
        desc "test", "run tests"
        define_method(:test) {}
      end
    end

    assert_match "depends_on accepts either task arguments or a block, not both", error.message
  end
end

class TestAsgardDependsOnShapeValidation < Minitest::Test
  def test_accepts_symbol_and_string_leaves
    klass = Class.new(Asgard::Base) do
      desc "build", "compile"
      define_method(:build) {}

      desc "lint", "lint"
      define_method(:lint) {}

      depends_on { [%i[build lint], "build"] }
      desc "test", "run tests"
      define_method(:test) {}
    end

    klass.validate_deps!
    assert_equal [%i[build lint], %i[build]], klass._deps[:test]
  end

  def test_bare_symbol_result_is_coerced_to_a_single_sequential_stage
    klass = Class.new(Asgard::Base) do
      desc "build", "compile"
      define_method(:build) {}

      depends_on { :build }
      desc "test", "run tests"
      define_method(:test) {}
    end

    klass.validate_deps!
    assert_equal [%i[build]], klass._deps[:test]
  end

  def test_rejects_stage_that_is_not_symbol_string_or_array
    klass = Class.new(Asgard::Base) do
      depends_on { [123] }
      desc "test", "run tests"
      define_method(:test) {}
    end

    error = assert_raises(Asgard::Error) { klass.validate_deps! }
    assert_match "depends_on proc/block for 'test' returned invalid stage 123 (Integer)", error.message
  end

  def test_rejects_non_symbol_leaf_inside_parallel_group
    klass = Class.new(Asgard::Base) do
      depends_on { [[:build, 123]] }
      desc "test", "run tests"
      define_method(:test) {}
    end

    error = assert_raises(Asgard::Error) { klass.validate_deps! }
    assert_match "depends_on proc/block for 'test' returned invalid dependency 123 (Integer) in a parallel group", error.message
  end

  def test_rejects_nesting_deeper_than_one_level
    klass = Class.new(Asgard::Base) do
      depends_on { [[[:build]]] }
      desc "test", "run tests"
      define_method(:test) {}
    end

    error = assert_raises(Asgard::Error) { klass.validate_deps! }
    assert_match "depends_on proc/block for 'test' returned invalid dependency [:build] (Array) in a parallel group", error.message
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
  def test_tasks_has_version_class_option
    assert Tasks.class_options.key?(:version)
  end

  def test_version_option_suppresses_negation_in_help
    usage = Tasks.class_options[:version].usage
    refute_match(/--no-version/, usage)
    refute_match(/--skip-version/, usage)
    assert_match(/--version/, usage)
  end

  def test_tasks_has_debug_class_option
    assert Tasks.class_options.key?(:debug)
  end

  def test_tasks_has_verbose_class_option
    assert Tasks.class_options.key?(:verbose)
  end

  def test_tasks_has_doctor_class_option
    assert Tasks.class_options.key?(:doctor)
  end

  def test_doctor_option_suppresses_negation_in_help
    usage = Tasks.class_options[:doctor].usage
    refute_match(/--no-doctor/, usage)
    refute_match(/--skip-doctor/, usage)
    assert_match(/--doctor/, usage)
  end
end

class TestAsgardHeaderFooter < Minitest::Test
  def setup
    @klass = Class.new(Asgard::Base)
    @klass.desc "go", "do the thing"
    @klass.define_method(:go) {}
  end

  def test_header_appends_lines
    @klass.header "line one"
    @klass.header "line two"
    assert_equal ["line one", "line two"], @klass.header
  end

  def test_footer_prepends_lines
    @klass.footer "line one"
    @klass.footer "line two"
    assert_equal ["line two", "line one"], @klass.footer
  end

  def test_header_appears_before_commands_in_help
    @klass.header "HEADER TEXT"
    out, = capture_io { @klass.start(["help"]) }
    assert out.index("HEADER TEXT") < out.index("Commands:")
  end

  def test_footer_appears_after_options_in_help
    @klass.footer "FOOTER TEXT"
    out, = capture_io { @klass.start(["help"]) }
    assert out.index("FOOTER TEXT") > out.index("Commands:")
  end

  def test_header_and_footer_absent_for_per_command_help
    @klass.header "HEADER TEXT"
    @klass.footer "FOOTER TEXT"
    out, = capture_io { @klass.start(%w[help go]) }
    refute_match "HEADER TEXT", out
    refute_match "FOOTER TEXT", out
  end

  def test_header_nil_by_default
    assert_nil @klass.header
  end

  def test_footer_nil_by_default
    assert_nil @klass.footer
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

  # Issue #1: a one-line script used to go through /bin/sh (dash on Debian)
  # while a heredoc went through bash. Both now run the :bash entry.
  def test_sh_runs_a_single_line_script_with_bash
    f = Tempfile.new("asgard_sh_bash")
    sh "echo $BASH_VERSION > #{f.path}", silent: true
    refute_empty File.read(f.path).strip
  ensure
    f.unlink
  end

  def test_shells_is_seeded_with_the_known_interpreters
    assert_equal %i[bash sh python3 python node ruby perl], Asgard::Shell.shells.keys
    assert_equal({ path: "bash", args: [], ext: ".sh" }, Asgard::Shell.shells[:bash])
    assert_equal({ path: "node", args: [], ext: ".js" }, Asgard::Shell.shells[:node])
  end

  def test_entry_splits_path_words_into_executable_and_args
    assert_equal({ path: "bash", args: %w[-eu -o pipefail], ext: ".sh" },
                 Asgard::Shell.entry("bash -eu -o pipefail"))
  end

  def test_entry_accepts_args_as_a_string_or_an_array_after_the_path_words
    expected = { path: "bash", args: %w[-eu -o pipefail -x], ext: ".sh" }
    assert_equal expected, Asgard::Shell.entry("bash -eu", args: "-o pipefail -x")
    assert_equal expected, Asgard::Shell.entry("bash -eu", args: %w[-o pipefail -x])
  end

  def test_entry_derives_the_extension_from_the_executable_basename
    assert_equal ".sh",  Asgard::Shell.entry("/opt/homebrew/bin/bash")[:ext]
    assert_equal ".py",  Asgard::Shell.entry("uv run --script", ext: ".py")[:ext]
    assert_equal ".tmp", Asgard::Shell.entry("uv run --script")[:ext]
  end

  def test_entry_honours_shell_quoting_in_the_path
    entry = Asgard::Shell.entry("'/Applications/Some App/bin/tool' -q")
    assert_equal ["/Applications/Some App/bin/tool", ["-q"]], entry.values_at(:path, :args)
  end

  def test_entry_rejects_an_empty_path
    assert_raises(ArgumentError) { Asgard::Shell.entry("  ") }
    assert_raises(ArgumentError) { Asgard::Shell.entry(Pathname.new("")) }
  end

  def test_entry_takes_a_pathname_whole_without_splitting_it
    entry = Asgard::Shell.entry(Pathname.new("/Applications/Some App/bin/bash"), args: "-eu")
    assert_equal({ path: "/Applications/Some App/bin/bash", args: ["-eu"], ext: ".sh" }, entry)
  end

  # A directory of executable stand-ins named +names+, so registration
  # tests exercise real files without depending on what this machine has.
  def with_executables(*names)
    Dir.mktmpdir("asgard_shells") do |dir|
      names.each do |name|
        file = File.join(dir, name)
        File.write(file, "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, file)
      end
      yield dir
    end
  end

  def test_shell_with_a_bare_path_names_the_entry_after_the_executable_and_parses_its_options
    with_executables("bash", "fish") do |dir|
      assert_equal :bash, Tasks.shell("#{dir}/bash -c -w")
      assert_equal({ path: "#{dir}/bash", args: %w[-c -w], ext: ".sh" }, Tasks.shells[:bash])

      assert_equal :fish, Tasks.shell(Pathname.new(dir).join("fish"))
      assert_equal({ path: "#{dir}/fish", args: [], ext: ".fish" }, Tasks.shells[:fish])
    end

    assert_equal :ruby, Tasks.shell("ruby -w", ext: ".rbx")
    assert_equal({ path: "ruby", args: %w[-w], ext: ".rbx" }, Tasks.shells[:ruby])
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_shell_with_a_symbol_alone_registers_that_name_from_path
    Tasks.shells.delete(:ruby)
    assert_equal :ruby, Tasks.shell(:ruby)
    assert_equal({ path: "ruby", args: [], ext: ".rb" }, Tasks.shells[:ruby])
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_shell_rejects_a_path_that_is_not_an_executable_file
    with_executables("bash") do |dir|
      File.write(File.join(dir, "notes.txt"), "")
      missing = assert_raises(ArgumentError) { Tasks.shell "#{dir}/zsh -f" }
      assert_equal "shell :zsh: #{dir}/zsh is not an executable file", missing.message
      plain = assert_raises(ArgumentError) { Tasks.shell :notes, "#{dir}/notes.txt" }
      assert_equal "shell :notes: #{dir}/notes.txt is not an executable file", plain.message
    end
    refute Tasks.shells.key?(:zsh)
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_shell_rejects_a_bare_name_that_is_not_on_path
    error = assert_raises(ArgumentError) { Tasks.shell :missing, "no_such_interpreter_xyz --flag" }
    assert_equal "shell :missing: no_such_interpreter_xyz is not an executable on PATH", error.message
    assert_raises(ArgumentError) { Tasks.shell :no_such_interpreter_xyz }
    assert_raises(ArgumentError) { Tasks.default_shell "no_such_interpreter_xyz" }
    assert_equal :bash, Tasks.default_shell
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_resolve_checks_a_path_as_a_file_and_a_bare_name_on_the_given_path
    with_executables("bash") do |dir|
      assert_equal "#{dir}/bash", Asgard::Shell.resolve("#{dir}/bash")
      assert_nil Asgard::Shell.resolve("#{dir}/zsh")
      assert_equal "#{dir}/bash", Asgard::Shell.resolve("bash", dir)
      assert_nil Asgard::Shell.resolve("zsh", dir)
      assert_nil Asgard::Shell.resolve("bash", "")
    end
  end

  def test_default_shell_with_a_bare_path_registers_then_selects_and_a_bare_name_only_selects
    with_executables("bash", "zsh") do |dir|
      Tasks.shell "#{dir}/bash -c -w"
      Tasks.default_shell :bash
      thing = Tasks.default_shell
      assert_equal :bash, thing
      assert_equal({ path: "#{dir}/bash", args: %w[-c -w], ext: ".sh" }, Tasks.shells[:bash],
                   "selecting by name must not re-register the pinned entry")

      assert_equal :zsh, Tasks.default_shell("#{dir}/zsh -f")
      assert_equal :zsh, Tasks.default_shell
      assert_equal({ path: "#{dir}/zsh", args: ["-f"], ext: ".sh" }, Tasks.shells[:zsh])
    end
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_default_shell_registers_and_selects_in_one_call
    Tasks.default_shell :strict, "bash", args: "-eu -o pipefail"
    assert_equal :strict, Tasks.default_shell
    assert_equal({ path: "bash", args: %w[-eu -o pipefail], ext: ".sh" }, Tasks.shells[:strict])

    Tasks.default_shell :traced, Pathname.new("/bin/bash"), args: %w[-x]
    assert_equal({ path: "/bin/bash", args: ["-x"], ext: ".sh" }, Tasks.shells[:traced])

    Tasks.default_shell :ruby, args: "-w"
    assert_equal :ruby, Tasks.default_shell
    assert_equal({ path: "ruby", args: ["-w"], ext: ".rb" }, Tasks.shells[:ruby])

    Tasks.default_shell :python3 # a bare name only selects
    assert_equal({ path: "python3", args: [], ext: ".py" }, Tasks.shells[:python3])
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_sh_runs_a_shell_declared_by_default_shell_in_one_call
    Tasks.default_shell :traced, Pathname.new("/bin/bash"), args: "-x"
    _, err = capture_subprocess_io { sh "echo one_call_marker", silent: true }
    assert_match(/^\+ echo one_call_marker/, err)
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_shell_for_falls_back_to_the_bare_name_on_path
    assert_equal({ path: "fish", args: [], ext: ".fish" }, Asgard::Shell.shell_for(:fish), "a known shell keeps its extension (C7)")
    assert_equal ".tmp", Asgard::Shell.shell_for(:no_such_shell_xyz)[:ext]
    assert_equal Asgard::Shell.shells[:ruby], Asgard::Shell.shell_for("ruby")
  end

  def test_argv_places_the_file_after_the_args
    entry = Asgard::Shell.entry("bash -x")
    assert_equal ["bash", "-x", "/tmp/asgard_1.sh"], Asgard::Shell.argv(entry, "/tmp/asgard_1.sh")
  end

  def test_default_shell_starts_as_bash_and_is_set_at_class_level
    assert_equal :bash, Tasks.default_shell
    Tasks.default_shell :zsh
    assert_equal :zsh, Tasks.default_shell
    assert_equal :zsh, Class.new(Tasks).default_shell
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_shebang_without_a_name_and_sh_both_run_the_default_shell
    Tasks.shell :traced, "bash -x"
    Tasks.default_shell :traced
    _, err = capture_subprocess_io do
      shebang "echo nameless_marker", silent: true
      sh "echo sh_marker", silent: true
    end
    assert_match(/^\+ echo nameless_marker/, err)
    assert_match(/^\+ echo sh_marker/, err)
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_shebang_returns_true_on_success
    assert_equal true, sh("true", silent: true)
    assert_equal true, shebang(:ruby, "exit 0", silent: true)
  end

  def test_shell_class_method_registers_an_entry_shared_by_every_tasks_subclass
    Tasks.shell :strict, "bash -eu -o pipefail"
    assert_equal({ path: "bash", args: %w[-eu -o pipefail], ext: ".sh" }, Tasks.shells[:strict])
    assert_same Tasks.shells, Class.new(Tasks).shells
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_shebang_runs_a_registered_shell_with_its_args
    Tasks.shell :traced, "bash -x"
    _, err = capture_subprocess_io { shebang :traced, "echo traced_marker", silent: true }
    assert_match(/^\+ echo traced_marker/, err)
  ensure
    Asgard::Shell.reset_shells!
  end

  def test_shebang_names_a_missing_shell_and_exits_127
    status = nil
    _, err = capture_io do
      status = assert_raises(SystemExit) { shebang :nonexistent_interpreter_xyz, "echo hi", silent: true }
    end
    assert_equal 127, status.status
    assert_match "shell :nonexistent_interpreter_xyz not found: nonexistent_interpreter_xyz ...", err
  end

  # Removed in 0.6.0: the shell is the unit of work, so there is nothing for
  # exec: to hand the process to.
  def test_sh_and_shebang_no_longer_accept_exec
    assert_raises(ArgumentError) { sh "true", exec: true }
    assert_raises(ArgumentError) { shebang :bash, "true", exec: true }
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

class TestAsgardDefaultTask < Minitest::Test
  def test_no_warning_on_first_default_task
    _, err = capture_io do
      Class.new(Asgard::Base) do
        desc "greet", "Say hello"
        define_method(:greet) {}
        default_task :greet
      end
    end
    refute_match "overrides", err
  end

  def test_warns_when_default_task_overridden
    _, err = capture_io do
      Class.new(Asgard::Base) do
        desc "greet", "Say hello"
        define_method(:greet) {}
        default_task :greet

        desc "bye", "Say goodbye"
        define_method(:bye) {}
        default_task :bye
      end
    end
    assert_match "overrides default_task :greet", err
    assert_match "default_task :bye",             err
  end

  def test_warning_includes_file_and_line_numbers
    _, err = capture_io do
      Class.new(Asgard::Base) do
        desc "a", "task a"
        define_method(:a) {}
        default_task :a
        desc "b", "task b"
        define_method(:b) {}
        default_task :b
      end
    end
    assert_match ".rb:", err
  end
end

class TestDoctorAncestorMarkers < Minitest::Test
  def test_finds_nearest_first
    Dir.mktmpdir do |root|
      root  = File.realpath(root)
      child = File.join(root, "child")
      Dir.mkdir(child)
      File.write(File.join(root,  ".loki"), "")
      File.write(File.join(child, ".loki"), "")

      markers = Asgard::Doctor.ancestor_markers(child)
      assert_equal File.join(child, ".loki"), markers.first
      assert_includes markers, File.join(root, ".loki")
    end
  end

  def test_empty_when_no_marker_exists
    Dir.mktmpdir do |dir|
      assert_empty Asgard::Doctor.ancestor_markers(File.realpath(dir))
    end
  end
end

class TestDoctorDuplicateMethods < Minitest::Test
  def test_flags_names_with_more_than_one_location
    log = { each: [["a.loki", 1], ["a.loki", 9]], once: [["a.loki", 1]] }
    dups = Asgard::Doctor.duplicate_methods(log)
    assert_equal %i[each], dups.keys
    assert_equal log[:each], dups[:each]
  end

  def test_flags_same_file_redefinition_not_only_cross_file
    # This is the exact shape of the real bug this feature exists to catch:
    # two `def each` in the *same* file, second one silently wins.
    log = { each: [["ws_git.loki", 28], ["ws_git.loki", 36]] }
    assert_equal %i[each], Asgard::Doctor.duplicate_methods(log).keys
  end

  def test_empty_when_every_name_defined_once
    log = { a: [["x.loki", 1]], b: [["y.loki", 2]] }
    assert_empty Asgard::Doctor.duplicate_methods(log)
  end
end

class TestDoctor < Minitest::Test
  def test_reports_no_loki_found
    Dir.mktmpdir do |dir|
      out, = capture_io { Asgard::Doctor.new(File.realpath(dir)).run }
      assert_match "no .loki file found", out
      assert_match "1 problem(s)", out
    end
  end

  def test_reports_shadowed_ancestor_markers
    Dir.mktmpdir do |root|
      root  = File.realpath(root)
      child = File.join(root, "child")
      Dir.mkdir(child)
      File.write(File.join(root,  ".loki"), "")
      File.write(File.join(child, ".loki"), "")

      out, = capture_io { Asgard::Doctor.new(child).run }
      assert_match "using .loki marker: #{File.join(child, '.loki')}", out
      assert_match "shadowed marker (never reached): #{File.join(root, '.loki')}", out
    end
  end

  def test_reports_import_chain
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, "extra.loki"), "")
      File.write(File.join(dir, ".loki"), 'import "extra.loki"')

      out, = capture_io { Asgard::Doctor.new(dir).run }
      assert_match(/import "extra\.loki" -> .*extra\.loki/, out)
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("extra.loki") }
  end

  def test_reports_load_failure_without_crashing
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), "this is not ruby (((")

      out, = capture_io { Asgard::Doctor.new(dir).run }
      assert_match "load failed", out
      assert_match "SyntaxError", out
    end
  end

  def test_reports_undefined_dependency
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), <<~RUBY)
        class Tasks
          depends_on :doctor_test_ghost
          desc "doctor_test_a", "a"
          def doctor_test_a = nil
        end
      RUBY

      out, = capture_io { Asgard::Doctor.new(dir).run }
      assert_match "undefined task(s) in depends_on: doctor_test_ghost", out
    end
  ensure
    Tasks.class_eval { remove_method(:doctor_test_a) rescue nil }
    Tasks._deps.delete(:doctor_test_a)
    Tasks._method_log.delete(:doctor_test_a)
    Tasks._reset_ran!
  end

  def test_detects_same_file_method_redefinition
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), <<~RUBY)
        class Tasks
          desc "doctor_test_dup", "first"
          def doctor_test_dup = :first

          desc "doctor_test_dup", "second"
          def doctor_test_dup = :second
        end
      RUBY

      out, = capture_io { Asgard::Doctor.new(dir).run }
      assert_match "doctor_test_dup  .loki:3   OVERRIDDEN by .loki:6", out
      assert_match "doctor_test_dup  .loki:6   active — redefines .loki:3", out
      assert_match "1 problem(s)", out
    end
  ensure
    Tasks.class_eval { remove_method(:doctor_test_dup) rescue nil }
    Tasks._method_log.delete(:doctor_test_dup)
    Tasks._reset_ran!
  end

  def test_clean_tree_reports_no_problems
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), <<~RUBY)
        class Tasks
          desc "doctor_test_clean", "ok"
          def doctor_test_clean = nil
        end
      RUBY

      out, = capture_io { Asgard::Doctor.new(dir).run }
      assert_match "No problems found", out
    end
  ensure
    Tasks.class_eval { remove_method(:doctor_test_clean) rescue nil }
    Tasks._method_log.delete(:doctor_test_clean)
    Tasks._reset_ran!
  end

  def test_import_tracer_keeps_only_loki_files
    added = ["/a/x.loki", "/gems/uri.rb", "/ruby/socket.bundle", "/a/y.loki"]
    assert_equal ["/a/x.loki", "/a/y.loki"], Asgard::Doctor::ImportTracer.loki_files(added)
  end

  def test_definition_site_keeps_a_normal_location
    loc = ["/proj/.loki", 12]
    assert_equal loc, Asgard::Base.definition_site(loc, caller_locations)
  end

  def test_definition_site_credits_thor_generated_methods_to_the_caller
    thor_loc = [File.join(Asgard::Base::THOR_LIB, "thor.rb"), 334]
    eval_loc = ["(eval at #{thor_loc.first}:643)", 2]
    here     = caller_locations(0, 1).first
    assert_equal [here.path, here.lineno + 1], Asgard::Base.definition_site(thor_loc, caller_locations(0))
    assert_equal [here.path, here.lineno + 2], Asgard::Base.definition_site(eval_loc, caller_locations(0))
  end

  def test_requires_and_subcommands_do_not_pollute_the_report
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, "helper_lib.rb"), "DOCTOR_HELPER_LIB = true")
      File.write(File.join(dir, "sub.loki"), <<~RUBY)
        require_relative "helper_lib"
        class DoctorSubCommands < Asgard::Base
          desc "go", "go"
          def go = nil
        end
        class Tasks
          desc "doctor_test_sub", "sub"
          subcommand "doctor_test_sub", DoctorSubCommands
        end
      RUBY
      File.write(File.join(dir, ".loki"), 'import "*.loki"')

      out, = capture_io { Asgard::Doctor.new(dir).run }
      assert_match(/import "\*\.loki" -> #{Regexp.escape(File.join(dir, 'sub.loki'))}\e/, out)
      refute_match "helper_lib.rb", out
      refute_match "thor", out
      assert_match "doctor_test_sub  sub.loki:8", out
      assert_match "help  sub.loki:8", out
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("sub.loki", "helper_lib.rb") }
    Tasks.class_eval { remove_method(:doctor_test_sub) rescue nil }
    Tasks._method_log.delete(:doctor_test_sub)
    Tasks.subcommands.delete("doctor_test_sub")
    Tasks.subcommand_classes.delete("doctor_test_sub")
    Tasks.commands.delete("doctor_test_sub")
    Tasks._reset_ran!
  end

  def test_relative_import_still_resolves_against_the_loki_file_not_doctor
    # Regression guard: Doctor's import tracer prepends `import` and calls
    # `super`, which used to shift `caller_locations` by one frame and break
    # resolution of a relative `import "x.loki"` path (see kernel_methods.rb's
    # `from:` keyword, threaded through explicitly for exactly this reason).
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, "sibling.loki"), "")
      File.write(File.join(dir, ".loki"), 'import "sibling.loki"')

      out, = capture_io { Asgard::Doctor.new(dir).run }
      refute_match "load failed", out
      assert_match "No problems found", out
    end
  ensure
    $LOADED_FEATURES.delete_if { |f| f.end_with?("sibling.loki") }
  end
end

# The six problems from notes/review_20261024.md, each pinned by a test.
class TestAsgardReviewFixes < Minitest::Test
  include Asgard::Shell

  def teardown
    Tasks._reset_ran!
    %i[iu_root iu_child].each do |name|
      Tasks.class_eval { remove_method(name) rescue nil }
      Tasks.commands.delete(name.to_s)
      Tasks._method_log.delete(name)
    end
  end

  # A project whose child file pulls the root in with import_up: the root
  # was never recorded as loaded, so the two files imported each other
  # until the stack overflowed.
  def with_import_up_project
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      Dir.mkdir(File.join(dir, "sub"))
      File.write(File.join(dir, "sub", "child.loki"), <<~RUBY)
        import_up
        class Tasks; desc "iu_child", "child"; def iu_child = nil; end
      RUBY
      File.write(File.join(dir, ".loki"), <<~RUBY)
        import "sub/*.loki"
        class Tasks; desc "iu_root", "root"; def iu_root = nil; end
      RUBY
      yield dir
    ensure
      $LOADED_FEATURES.delete_if { |f| f.start_with?(dir) }
    end
  end

  def test_import_up_from_an_imported_file_loads_the_root_once
    with_import_up_project do |dir|
      capture_io { Dir.chdir(dir) { Asgard.run!(["help"]) } }
      assert Tasks.method_defined?(:iu_child)
      assert_equal 1, Tasks._method_log[:iu_root].size, "the root .loki should load exactly once"
    end
  end

  def test_doctor_survives_import_up_from_an_imported_file
    with_import_up_project do |dir|
      out, = capture_io { Dir.chdir(dir) { Asgard::Doctor.new(dir).run } }
      refute_match "load failed", out
      assert_match "iu_child", out
    end
  end

  def test_sh_reports_a_signalled_child_as_128_plus_the_signal
    e = assert_raises(SystemExit) { sh "kill -9 $$", silent: true }
    assert_equal 137, e.status
  end

  def test_shell_exit_code_prefers_the_status_and_falls_back_to_the_signal
    exited   = Struct.new(:exitstatus, :termsig).new(3, nil)
    killed   = Struct.new(:exitstatus, :termsig).new(nil, 15)
    assert_equal 3,   Asgard::Shell.exit_code(exited)
    assert_equal 143, Asgard::Shell.exit_code(killed)
  end

  def parallel_group(first_body, &second_body)
    completed = []
    mu        = Mutex.new
    klass     = Class.new(Asgard::Base) do
      desc "first", "first"
      define_method(:first, &first_body)

      desc "second", "second"
      define_method(:second) do
        sleep 0.05
        mu.synchronize { completed << :second }
        second_body&.call
      end

      depends_on %i[first second]
      desc "target", "target"
      define_method(:target) {}
    end
    [klass, completed]
  end

  def test_a_failing_sh_in_a_parallel_group_waits_for_its_siblings
    klass, completed = parallel_group(-> { exit 7 })
    e = assert_raises(SystemExit) { klass.new([], {}, {}).invoke(:target) }
    assert_equal 7, e.status
    assert_includes completed, :second
  end

  def test_a_raising_parallel_dep_does_not_print_a_thread_report
    klass, = parallel_group(-> { raise "boom" })
    _, err = capture_io { assert_raises(RuntimeError) { klass.new([], {}, {}).invoke(:target) } }
    refute_match(/terminated with exception/, err)
  end

  def test_several_failing_parallel_deps_are_each_named
    klass, = parallel_group(-> { exit 3 }) { raise "boom" }
    error  = nil
    _, err = capture_io { error = assert_raises(Asgard::Error) { klass.new([], {}, {}).invoke(:target) } }
    assert_equal "parallel dependencies failed: first, second", error.message
    assert_match "dependency 'first' failed: exit 3", err
    assert_match "dependency 'second' failed: RuntimeError: boom", err
  end

  def test_a_task_named_after_a_thor_internal_is_rejected_with_its_location
    e = assert_raises(Asgard::Error) do
      Class.new(Asgard::Base) do
        desc "args", "args"
        define_method(:args) {}
      end
    end
    assert_match(/'args' at .*test_asgard\.rb:\d+ is a name Thor reserves/, e.message)
  end

  def test_a_helper_named_after_a_thor_reserved_word_is_rejected
    e = assert_raises(Asgard::Error) do
      Class.new(Asgard::Base) { no_commands { define_method(:shell) {} } }
    end
    assert_match "'shell' at", e.message
  end

  def test_run_reports_a_reserved_task_name_as_an_asgard_error
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), "class Tasks; desc 'args', 'x'; def args = nil; end")
      _, err = capture_io { assert_raises(SystemExit) { Dir.chdir(dir) { Asgard.run!(["help"]) } } }
      assert_match "asgard: 'args' at #{dir}/.loki:1 is a name Thor reserves", err
    ensure
      $LOADED_FEATURES.delete_if { |f| f.start_with?(dir) }
    end
  end
end

class TestAsgardCurrentTask < Minitest::Test
  def setup
    @seen  = {}
    seen   = @seen
    mutex  = Mutex.new
    @klass = Class.new(Asgard::Base) do
      desc "db", "db"
      define_method(:db) { mutex.synchronize { seen[:db] = [current_task, next_job_sequence, next_job_sequence] } }

      desc "api", "api"
      define_method(:api) { mutex.synchronize { seen[:api] = [current_task, next_job_sequence] } }

      depends_on %i[db api]
      desc "servers", "servers"
      define_method(:servers) { mutex.synchronize { seen[:servers] = [current_task, next_job_sequence] } }
    end
  end

  def test_each_task_body_sees_its_own_name_even_in_a_parallel_stage
    @klass.new([], {}, {}).invoke(:servers)
    assert_equal [:db, 1, 2], @seen[:db]
    assert_equal [:api, 1],   @seen[:api]
    assert_equal [:servers, 1], @seen[:servers]
  end

  def test_the_sequence_starts_over_on_each_run_and_the_frame_is_popped
    runner = @klass.new([], {}, {})
    runner.invoke(:api)
    @klass._reset_ran!
    runner.invoke(:api)
    assert_equal [:api, 1], @seen[:api], "a new run of the body counts from 1 again"
    assert_nil runner.current_task, "no task is running once invoke returns"
  end

  def test_outside_a_task_there_is_no_current_task_and_no_sequence
    runner = @klass.new([], {}, {})
    assert_nil runner.current_task
    error = assert_raises(Asgard::Error) { runner.next_job_sequence }
    assert_match(/no task is running/, error.message)
  end
end

# C1: a task waiting on a shared dependency that failed must not run.
class TestRegressionSharedDependencyFailure < Minitest::Test
  include AsgardProcess

  def test_regression_c1_waiter_does_not_run_after_shared_dep_fails
    ran  = []
    lock = Mutex.new
    klass = Class.new(Asgard::Base) do
      desc "a", "a"
      define_method(:a) do
        sleep 0.2
        raise Asgard::Error, "a broke"
      end
      depends_on :a
      desc "b", "b"
      define_method(:b) { lock.synchronize { ran << :b } }
      depends_on :a
      desc "c", "c"
      define_method(:c) { lock.synchronize { ran << :c } }
      depends_on %i[b c]
      desc "top", "top"
      define_method(:top) { lock.synchronize { ran << :top } }
    end
    klass.validate_deps!
    capture_io { assert_raises(Asgard::Error) { klass.new([], {}, {}).invoke(:top) } }
    assert_empty ran, "no task that depends on the failed :a may run"
  end

  def test_regression_c1_shared_dep_exit_status_ends_asgard_and_no_waiter_runs
    loki = <<~LOKI
      class Tasks
        desc "a"; def a = sh("sleep 0.3; exit 3", silent: true)
        depends_on :a
        desc "b"; def b = puts("B RAN")
        depends_on :a
        desc "c"; def c = puts("C RAN")
        depends_on [:b, :c]
        desc "top"; def top = puts("TOP RAN")
      end
    LOKI
    out, _err, status = run_asgard(loki, "top")
    assert_equal 3, status.exitstatus, "the failing dependency's own status"
    refute_match(/[BC] RAN|TOP RAN/, out)
  end

  def test_regression_c1_primary_failures_drop_the_ones_caused_by_another
    dispatch = Asgard::Base::Dispatch
    primary  = dispatch::DepExit.new(3)
    derived  = dispatch::DepFailed.new(:a, primary)
    assert_equal({ b: primary }, dispatch.primary_failures({ b: primary, c: derived }))
    assert_equal({ c: derived }, dispatch.primary_failures({ c: derived }), "only derived: keep them")
  end
end

# C3 (decision D3): a public method with no desc is a hidden task, and a
# depends_on always attaches to the very next method.
class TestRegressionHiddenTasks < Minitest::Test
  include AsgardProcess

  def build
    ran = @ran = []
    Class.new(Asgard::Base) do
      desc "a", "a"
      define_method(:a) { ran << :a }

      depends_on :a
      define_method(:setup_x) { ran << :setup_x }

      desc "later", "later"
      define_method(:later) { ran << :later }

      depends_on :setup_x
      desc "uses", "uses"
      define_method(:uses) { ran << :uses }

      no_commands { define_method(:inner) { :inner } }
      helper(:helped) { :helped }
      define_method(:_gem_owned) { :gem }

      private

      define_method(:secret_helper) { :private }
    end
  end

  def test_regression_c3_depends_on_attaches_to_the_next_method_without_desc
    klass = nil
    capture_io { klass = build }
    assert_equal [[:a]], klass._deps[:setup_x]
    refute klass._deps.key?(:later), "later declared no dependency"
  end

  def test_regression_c3_a_method_without_desc_is_a_hidden_command_and_no_warning
    klass = nil
    out, = capture_io { klass = build }
    refute_match(/"setup_x" without usage or description/, out)
    assert_kind_of Thor::HiddenCommand, klass.all_commands["setup_x"]
    help, = capture_io { klass.new([], {}, {}).help }
    refute_match(/setup_x/, help)
    assert_match(/later/, help)
  end

  def test_regression_c3_a_hidden_task_is_a_dependency_and_runs_once
    klass = nil
    capture_io { klass = build }
    klass.validate_deps!
    klass.new([], {}, {}).invoke(:uses)
    assert_equal %i[a setup_x uses], @ran
  end

  def test_regression_c3_helpers_private_and_gem_methods_stay_out
    klass = nil
    capture_io { klass = build }
    %w[inner helped _gem_owned secret_helper].each { |name| refute klass.all_commands.key?(name), name }
  end

  def test_regression_c3_a_hidden_task_runs_from_the_command_line
    out, _err, status = run_asgard(%(class Tasks\n  def setup_x = puts("SETUP RAN")\nend\n), "setup_x")
    assert_equal 0, status.exitstatus
    assert_equal "SETUP RAN\n", out
  end

  def test_regression_c3_doctor_lists_hidden_tasks
    out, = run_asgard(%(class Tasks\n  def setup_x = nil\n  desc "shown"\n  def shown = nil\nend\n), "--doctor")
    assert_match(/setup_x.*hidden/, out)
    refute_match(/shown.*hidden/, out)
  end
end

# C4: a .loki that fails to load says so in one line, not a backtrace.
class TestRegressionLoadErrors < Minitest::Test
  include AsgardProcess

  CASES = {
    "missing import" => ['import "missing.loki"', /missing\.loki/],
    "bad shell path" => ["class Tasks\n  shell :x, \"/no/such/shell\"\nend", %r{/no/such/shell}],
    "syntax error"   => ["class Tasks\n  def oops(\nend", /syntax/i],
    "typo"           => ["class Tasks\n  dependz_on :x\nend", /dependz_on/]
  }.freeze

  def test_regression_c4_load_errors_are_one_line_with_the_loki_location
    CASES.each do |label, (loki, pattern)|
      _out, err, status = run_asgard(loki, "help")
      assert_equal 1, status.exitstatus, "#{label}: exit status"
      lines = err.lines.reject { |line| line.strip.empty? }
      assert_equal 1, lines.size, "#{label}: one line, got:\n#{err}"
      assert_match(/\Aasgard: .*\.loki:\d+/, lines.first, label)
      assert_match pattern, lines.first, label
    end
  end

  def test_regression_c4_asgard_trace_shows_the_backtrace
    _out, err, status = run_asgard(CASES["typo"].first, "help", env: { "ASGARD_TRACE" => "1" })
    refute_equal 0, status.exitstatus
    assert_match(/^\s+from |:in /, err)
  end

  def test_regression_c4_load_error_message_is_pure
    error = NameError.new("undefined local variable or method 'dependz_on'")
    error.set_backtrace(["/lib/asgard/x.rb:1:in 'y'", "/proj/.loki:2:in '<class:Tasks>'", "/proj/.loki:1:in '<top>'"])
    assert_equal "/proj/.loki:2: undefined local variable or method 'dependz_on' (NameError)", Asgard.load_error_message(error)
  end
end

# J8, J9: background jobs from the command line.
class TestRegressionJobsFromTheCommandLine < Minitest::Test
  include AsgardProcess

  def test_regression_j8_bare_asgard_jobs_lists_outside_a_project
    assert Asgard.machine_wide?(%w[jobs])
  end

  # A task that changes directory into a nested project before starting a
  # job still files the job under the project asgard was run in.
  def test_regression_j9_a_job_is_filed_under_the_project_asgard_ran_in
    Dir.mktmpdir do |state_home|
      loki = <<~LOKI
        class Tasks
          desc "serve"
          def serve
            Dir.chdir("sub")
            sh "sleep 30", background: :srv
          end
        end
      LOKI
      out, err, status = run_asgard(loki, "serve", files: { "sub/.loki" => "" }, env: { "XDG_STATE_HOME" => state_home })
      assert_equal 0, status.exitstatus, err
      log = out[/log: (\S+)/, 1]
      assert log, out
      assert_match(%r{/jobs/d\d+-\d+-\w+-\h{8}/srv\.log\z}, log, "the root project's slug, not sub's")
    ensure
      Dir.glob(File.join(state_home, "asgard", "jobs", "*", "*.json")).each do |file|
        record = Asgard::StateDir.read_json(file)
        Asgard::Jobs::Stopper.signal_group("KILL", record[:pgid]) if Asgard::Jobs::State.verified?(record)
      end
    end
  end
end

# Phase 3 core regressions.
class TestRegressionCoreLow < Minitest::Test
  include AsgardProcess

  ECHO_ARGS = %(class Tasks\n  desc "echo_args [ARGS]"\n  def echo_args(*args) = puts(args.inspect)\nend\n)

  # C5: --version and --doctor are asgard's only before the task name.
  def test_regression_c5_flags_after_the_task_name_belong_to_the_task
    out, _err, status = run_asgard(ECHO_ARGS, "echo_args", "--", "--version")
    assert_equal 0, status.exitstatus
    assert_equal %(["--version"]\n), out
    assert Asgard.leading_flag?(%w[--version], "--version")
    refute Asgard.leading_flag?(%w[echo_args --version], "--version")
    assert Asgard.leading_flag?(%w[--debug --doctor], "--doctor")
  end

  # C6: a directory named .loki is not a task file.
  def test_regression_c6_a_loki_directory_is_skipped
    Dir.mktmpdir do |dir|
      real = File.realpath(dir)
      File.write(File.join(real, ".loki"), "")
      FileUtils.mkdir_p(File.join(real, "sub", ".loki"))
      Dir.chdir(File.join(real, "sub")) do
        assert_equal File.join(real, ".loki"), loki_up.to_s
        assert_equal [File.join(real, ".loki")], Asgard::Doctor.ancestor_markers(Dir.pwd).first(1)
      end
    end
  end

  # C7: an unregistered shell gets its known extension, and selecting one
  # that is not there fails as the .loki loads.
  def test_regression_c7_unregistered_shells
    assert_equal ".sh",   Asgard::Shell.shell_for(:zsh)[:ext]
    assert_equal ".fish", Asgard::Shell.shell_for(:fish)[:ext]
    assert_raises(ArgumentError) { Tasks.default_shell(:no_such_shell_xyz) }
  ensure
    Asgard::Shell.reset_shells!
  end

  # C8: parallel dependencies each get their own instance.
  def test_regression_c8_parallel_dependencies_do_not_share_instance_variables
    seen = {}
    lock = Mutex.new
    klass = Class.new(Asgard::Base) do
      { a: 0.1, b: 0.0 }.each do |name, pause|
        desc name.to_s, name.to_s
        define_method(name) do
          @mine = name
          sleep pause + 0.1
          lock.synchronize { seen[name] = @mine }
        end
      end
      depends_on %i[a b]
      desc "top", "top"
      define_method(:top) { nil }
    end
    klass.validate_deps!
    klass.new([], {}, {}).invoke(:top)
    assert_equal({ a: :a, b: :b }, seen)
  end

  # C9: Tasks.subclasses is Ruby's Class#subclasses.
  def test_regression_c9_subclasses_is_rubys
    child = Class.new(Tasks)
    assert_includes Tasks.subclasses, child
    assert_includes Asgard::Base._asgard_subclasses, child
  end

  # C10: the gem's release prompt survives stdin at end-of-file.
  def test_regression_c10_release_aborts_on_eof
    loki = <<~LOKI
      class Tasks
        @@project = "x"
        helper(:project_version) { "0.0.0" }
        desc "quality"; def quality = nil
      end
      import "gem_tasks.loki"
    LOKI
    out, err, status = run_asgard(loki, "release", files: { "gem_tasks.loki" => File.read(File.expand_path("../gem_tasks.loki", __dir__)) })
    assert_equal 0, status.exitstatus, err
    assert_match(/Aborted\./, out)
  end
end
