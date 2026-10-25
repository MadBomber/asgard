# frozen_string_literal: true

require_relative "lib/asgard/version"

Gem::Specification.new do |spec|
  spec.name = "asgard"
  spec.version = Asgard::VERSION
  spec.authors = ["Dewayne VanHoozer"]
  spec.email = ["dewayne@vanhoozer.me"]

  spec.summary = "A powerful Ruby-based task runner"
  spec.description = <<~DESC
    A powerful Ruby-based task runner for any kind of project with task dependency tracking
    and concurrent execution of designated tasks. Uses Thor for its rich CLI options, with
    dotenv, sh/shebang helpers, importable task files, scheduled execution of tasks via
    launchd (macOS) or systemd timers (Linux), a file watcher and background jobs.
  DESC
  spec.homepage = "https://github.com/madbomber/asgard"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  # The library, its executable and signatures, and the three documents a
  # user of the installed gem reads; the docs site, examples and the gem's
  # own dev task files stay in the repository.
  shipped = %r{\A(?:lib/|bin/asgard\z|sig/)|\A(?:README\.md|LICENSE\.txt|CHANGELOG\.md)\z}
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).grep(shipped)
  end
  spec.bindir = "bin"
  spec.executables = ["asgard"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor"          # Thor is a toolkit for building powerful command-line interfaces.
  spec.add_dependency "dotenv"        # Loads environment variables from `.env`.
  spec.add_dependency "tty-table"     # A flexible and intuitive table generator
  spec.add_dependency "ractor_queue"  # Ractor-shareable bounded queue for Ruby parallel workloads
  spec.add_dependency "listen"        # Listen to file modifications
  spec.add_dependency "tsort"         # Topological sorting using Tarjan's algorithm

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
