# frozen_string_literal: true

require "test_helper"

# Phase 4: what the published gem says about itself and what it ships.
class TestGemspec < Minitest::Test
  SPEC = Gem::Specification.load(File.expand_path("../asgard.gemspec", __dir__))

  def test_regression_p2_the_description_names_only_real_features
    refute_match(/var\s+declarations/, SPEC.description)
  end

  def test_regression_p3_the_changelog_link_is_on_the_main_branch
    assert_includes SPEC.metadata["changelog_uri"], "/blob/main/"
  end

  def test_the_docs_site_and_issue_tracker_are_linked
    site_url = File.read(File.expand_path("../mkdocs.yml", __dir__))[/^site_url:\s*(\S+)/, 1]
    assert_equal site_url, SPEC.metadata["documentation_uri"]
    assert_equal "#{SPEC.homepage}/issues", SPEC.metadata["bug_tracker_uri"]
  end

  def test_regression_p4_only_the_library_and_its_docs_are_packaged
    dev    = /\A(?:CLAUDE\.md|COMMITS\.md|\.envrc|mkdocs\.yml|Archspec\.rb|\.rubocop\.yml|\.reek\.yml)\z|\.loki\z/
    leaked = SPEC.files.grep(%r{\A(?:docs/|notes/|examples/|\.github/|site/)}) + SPEC.files.grep(dev)
    assert_empty leaked
    %w[lib/asgard.rb bin/asgard README.md LICENSE.txt CHANGELOG.md].each { |file| assert_includes SPEC.files, file }
  end
end
