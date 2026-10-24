# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

module Asgard
  # The layout every kind of per-project state shares: a directory per
  # project under $XDG_STATE_HOME/asgard/<kind>/<project-slug>/ (by default
  # ~/.local/state), a file in it naming the project root so a machine-wide
  # listing can find every project without loading its .loki, and JSON
  # records written whole then renamed. The watcher files its state under
  # "watch" and background jobs under "jobs".
  module StateDir
    ROOT_FILE = "root"

    module_function

    def base_dir(kind, home: Dir.home, env: ENV)
      File.join(env["XDG_STATE_HOME"] || File.join(home, ".local", "state"), "asgard", kind.to_s)
    end

    # Every project with a state directory under base, as [slug, root] pairs.
    def all(kind = nil, base: base_dir(kind))
      Dir.glob(File.join(base, "*", ROOT_FILE)).map do |file|
        [File.basename(File.dirname(file)), File.read(file).strip]
      end
    end

    # Written whole then renamed, so a reader never sees a partial file.
    # The tempfile is a dotfile: a "*.json" glob or a name pattern that
    # lists records never picks up one that is still being written.
    def write_json(path, value)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      Tempfile.create([".asgard", ".json"], dir) do |file|
        file.write(JSON.pretty_generate(value))
        file.flush
        File.rename(file.path, path)
      end
    end

    def read_json(path) = File.exist?(path) ? JSON.parse(File.read(path), symbolize_names: true) : nil

    # Creates +dir+ and records the project root in it.
    def record_root(dir, root)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ROOT_FILE), "#{root}\n")
    end
  end
end
