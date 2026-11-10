# frozen_string_literal: true

require "test_helper"
require "date"
require "yaml"

# docs/llms.txt (https://llmstxt.org) must open with the site's name and
# description and link every page in the mkdocs nav and nothing else, so it
# cannot drift from the site.
class TestLlmsTxt < Minitest::Test
  ROOT  = File.expand_path("..", __dir__)
  LLMS  = File.join(ROOT, "docs/llms.txt")
  ENTRY = /\A- \[[^\]]+\]\((\S+)\): \S/

  # mkdocs.yml as data. Its !!python/name tags name Python objects that
  # safe_load rejects; they are nulled, since only plain keys are read here.
  def self.mkdocs_config(text)
    YAML.safe_load(text.gsub(%r{!!python/[^\s,\]\}]+}, "null"), aliases: true, permitted_classes: [Date, Time, Symbol])
  end

  # The docs pages in a nav, in order. External links are not pages.
  def self.nav_pages(nav)
    case nav
    when String then [nav].grep(/\A[^:]+\.md\z/)
    when Hash   then nav_pages(nav.values)
    else Array(nav).flat_map { nav_pages(it) }
    end
  end

  # Where mkdocs serves a page: index.md at "<site_url>/", tasks.md at "<site_url>/tasks/".
  def self.url_for(page, site_url)
    site_url.chomp("/") + "/#{page}".sub(%r{/index\.md\z}, "/").sub(/\.md\z/, "/")
  end

  def config = @config ||= self.class.mkdocs_config(File.read(File.join(ROOT, "mkdocs.yml")))

  def llms_text
    assert_path_exists LLMS
    File.read(LLMS)
  end

  def entries = llms_text.lines.grep(/\A\s*[-*+] /)

  def test_it_opens_with_the_site_name_and_description
    assert llms_text.start_with?("# #{config.fetch('site_name')}\n\n> #{config.fetch('site_description')}\n"),
           "llms.txt must open with mkdocs.yml's site_name as its H1 and site_description as its > summary"
  end

  def test_every_list_entry_is_a_described_link
    lines = entries
    refute_empty lines
    lines.each { assert_match ENTRY, it }
  end

  def test_it_links_every_page_in_the_nav_and_nothing_else
    nav_urls = self.class.nav_pages(config.fetch("nav")).map { self.class.url_for(it, config.fetch("site_url")) }
    assert_equal nav_urls.sort, entries.filter_map { it[ENTRY, 1] }.sort
  end

  def test_url_for_maps_docs_files_to_site_urls
    site = "https://example.com/asgard"
    assert_equal "#{site}/", self.class.url_for("index.md", site)
    assert_equal "#{site}/task-files/", self.class.url_for("task-files.md", "#{site}/")
    assert_equal "#{site}/guide/", self.class.url_for("guide/index.md", site)
    assert_equal "#{site}/guide/setup/", self.class.url_for("guide/setup.md", site)
  end

  def test_nav_pages_flattens_sections_and_drops_external_links
    nav = [{ "Home" => "index.md",
           "Group" => [{ "A" => "a.md" }, { "B" => "b.md" }],
           "Empty" => nil,
           "GitHub" => "https://github.com/MadBomber/asgard",
           "Mail" => "mailto:someone@example.com",
           "Contributing" => "https://github.com/MadBomber/asgard/blob/main/CONTRIBUTING.md" }]
    assert_equal %w[index.md a.md b.md], self.class.nav_pages(nav)
  end

  def test_mkdocs_config_reads_past_python_tags
    yml = <<~YAML
      site_url: "https://example.com/x/"  # pages
      site_description: >-
        Two
        lines.
      gen: !!python/name:material.extensions.emoji.to_svg
      fences: [{name: mermaid, format: !!python/name:pymdownx.superfences.fence_code_format}]
      released: 2026-01-01
      nav:  # pages
        - Home: index.md
    YAML
    config = self.class.mkdocs_config(yml)
    assert_equal "https://example.com/x/", config["site_url"]
    assert_equal "Two lines.", config["site_description"]
    assert_nil config["gen"]
    assert_equal [{ "name" => "mermaid", "format" => nil }], config["fences"]
    assert_equal [{ "Home" => "index.md" }], config["nav"]
  end
end
