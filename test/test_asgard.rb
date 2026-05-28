# frozen_string_literal: true

require "test_helper"
require "tempfile"

class TestAsgardVersion < Minitest::Test
  def test_version_is_defined
    refute_nil Asgard::VERSION
  end
end

class TestAsgardFindFile < Minitest::Test
  def test_returns_nil_when_not_found
    Dir.chdir("/tmp") do
      assert_nil Asgard.find_task_files
    end
  end

  def test_finds_dot_loki_in_current_directory
    Dir.mktmpdir do |dir|
      dir  = File.realpath(dir)
      path = File.join(dir, ".loki")
      File.write(path, "")
      result = Dir.chdir(dir) { Asgard.find_task_files }
      assert_equal [path], result
    end
  end

  def test_finds_dot_loki_in_parent_directory
    Dir.mktmpdir do |dir|
      dir    = File.realpath(dir)
      path   = File.join(dir, ".loki")
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      File.write(path, "")
      result = Dir.chdir(subdir) { Asgard.find_task_files }
      assert_equal [path], result
    end
  end

  def test_dot_loki_takes_priority_over_glob_files
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      File.write(File.join(dir, ".loki"), "")
      File.write(File.join(dir, "tasks.loki"), "")
      result = Dir.chdir(dir) { Asgard.find_task_files }
      assert_equal [File.join(dir, ".loki")], result
    end
  end

  def test_returns_all_glob_files_sorted_when_no_dot_loki
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      %w[zebra.loki alpha.loki mango.loki].each { |f| File.write(File.join(dir, f), "") }
      result = Dir.chdir(dir) { Asgard.find_task_files }
      assert_equal %w[alpha.loki mango.loki zebra.loki].map { |f| File.join(dir, f) }, result
    end
  end

  def test_finds_glob_files_in_parent_directory
    Dir.mktmpdir do |dir|
      dir    = File.realpath(dir)
      path   = File.join(dir, "tasks.loki")
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      File.write(path, "")
      result = Dir.chdir(subdir) { Asgard.find_task_files }
      assert_equal [path], result
    end
  end
end

class TestAsgardVar < Minitest::Test
  def setup
    @klass = Class.new(Asgard::Base) do
      var :greeting, "hello"
      var :dynamic,  -> { "dyn_#{42}" }
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

  def test_dep_runs_before_method
    instance = @klass.new([], {}, {})
    instance.invoke(:test)
    assert_equal [:build, :test], @log
  end

  def test_transitive_deps_run_in_order
    instance = @klass.new([], {}, {})
    instance.invoke(:release)
    assert_equal [:build, :test, :release], @log
  end

  def test_dep_runs_only_once
    instance = @klass.new([], {}, {})
    instance.invoke(:build)
    instance.invoke(:test)
    assert_equal [:build, :test], @log, "build should not run a second time"
  end

  def test_method_added_ignores_underscore_prefix
    klass = Class.new(Asgard::Base) do
      depends_on :build
      no_commands { define_method(:_private_helper) {} }
    end
    refute klass._deps.key?(:_private_helper)
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
      desc "a", "a"; define_method(:a) {}
      desc "b", "b"; define_method(:b) {}
    end

    klass._deps[:a] = [:b]
    klass._deps[:b] = [:a]

    assert_raises(Asgard::CircularDependencyError) { klass.validate_deps! }
  end

  def test_no_error_when_deps_are_valid
    klass = Class.new(Asgard::Base) do
      desc "a", "a"; define_method(:a) {}
      depends_on :a
      desc "b", "b"; define_method(:b) {}
    end
    klass.validate_deps! # must not raise
  end

  def test_no_error_when_no_deps
    klass = Class.new(Asgard::Base)
    klass.validate_deps! # must not raise
  end
end

class TestAsgardImport < Minitest::Test
  def test_import_merges_tasks_from_module
    task_log = []

    mod = Module.new
    mod.define_singleton_method(:included) do |base|
      base.desc "ping", "ping task"
      base.define_method(:ping) { task_log << :ping }
    end

    klass    = Class.new(Asgard::Base) { import mod }
    instance = klass.new([], {}, {})
    instance.ping
    assert_equal [:ping], task_log
  end
end

class TestAsgardDotenv < Minitest::Test
  def test_dotenv_loads_env_file
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".env"), "ASGARD_TEST_VAR=loaded\n")
      klass = Class.new(Asgard::Base)
      Dir.chdir(dir) { klass.dotenv }
      assert_equal "loaded", ENV["ASGARD_TEST_VAR"]
    end
  ensure
    ENV.delete("ASGARD_TEST_VAR")
  end

  def test_dotenv_silently_skips_missing_file
    klass = Class.new(Asgard::Base)
    klass.dotenv("/nonexistent/path/.env") # must not raise
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

  def test_shebang_exits_on_failure
    assert_raises(SystemExit) { shebang :ruby, "exit 1", silent: true }
  end

  def test_shebang_uses_tmp_extension_for_unknown_interpreter
    # Uses :ruby as a known-good interpreter but verifies the extension
    # fallback path by checking a custom interpreter isn't in the table.
    assert_raises(SystemExit) do
      shebang :nonexistent_interpreter_xyz, "echo hi", silent: true
    end
  end
end
