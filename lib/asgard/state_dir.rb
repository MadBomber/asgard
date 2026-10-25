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

    # The size a log may reach before it is rotated, unless ASGARD_LOG_MAX
    # (bytes) says otherwise.
    LOG_MAX = 10 * 1024 * 1024

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

    # The parsed record, or nil when there is none or it is not JSON (a
    # disk that filled up, a hand edit): one bad file must not take down
    # every listing that reads it.
    def read_json(path)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path), symbolize_names: true)
    rescue JSON::ParserError
      nil
    end

    # The log size limit: ASGARD_LOG_MAX when it is a positive number of
    # bytes, else LOG_MAX.
    def log_limit(env = ENV)
      bytes = Integer(env["ASGARD_LOG_MAX"].to_s, exception: false)
      bytes&.positive? ? bytes : LOG_MAX
    end

    # Moves +path+ to +path+.1 (replacing an older one) once it is larger
    # than +max_bytes+; the new name when it did, else nil. A task still
    # writing to the old file carries on into path.1, and the next line
    # starts a fresh file.
    def rotate(path, max_bytes:)
      return nil unless File.exist?(path) && File.size(path) > max_bytes

      File.rename(path, "#{path}.1")
      "#{path}.1"
    end

    # Creates +dir+, readable by its owner only (logs and job scripts can
    # hold secrets), and records the project root in it.
    def record_root(dir, root)
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.chmod(0o700, dir)
      File.write(File.join(dir, ROOT_FILE), "#{root}\n")
    end
  end
end
