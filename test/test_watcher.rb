# frozen_string_literal: true

require "test_helper"
require "tmpdir"

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
