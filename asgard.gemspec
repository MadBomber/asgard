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
    and concurrent execution of designated tasks. Uses Thor for its rich CLI options, var
    declarations, dotenv, sh/shebang helpers, and importable task files.
  DESC
  spec.homepage = "https://github.com/madbomber/asgard"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[Gemfile .gitignore test/])
    end
  end
  spec.bindir = "bin"
  spec.executables = ["asgard"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor",    "~> 1.0"
  spec.add_dependency "dagwood", "~> 1.0"
  spec.add_dependency "dotenv",  "~> 3.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
