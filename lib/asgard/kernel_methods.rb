# frozen_string_literal: true

module Kernel
  def debug?   = $DEBUG
  def verbose? = $VERBOSE
  module_function :debug?, :verbose?

  # Fetch an environment variable by symbol or string name.
  # The name is converted to an uppercase string automatically.
  # Raises KeyError when the variable is missing and no default is given.
  def env(name, default = nil)
    key = name.to_s.upcase
    default.nil? ? ENV.fetch(key) : ENV.fetch(key, default)
  end
  module_function :env

  def loki_up(name = ".loki")
    dir = Dir.pwd
    loop do
      candidate = File.join(dir, name)
      return candidate if File.exist?(candidate)
      parent = File.dirname(dir)
      break if parent == dir
      dir = parent
    end
    nil
  end
  module_function :loki_up

  def import(path)
    path = path.to_s
    raise ArgumentError, "import: path must end with .loki (got #{path.inspect})" unless path.end_with?(".loki")
    unless File.absolute_path?(path)
      caller_dir = File.dirname(caller_locations(1, 1).first.absolute_path)
      path = File.expand_path(path, caller_dir)
    end
    paths = path =~ /[*?\[{]/ ? Dir.glob(path) : [path]
    loaded = paths.map do |p|
      if $LOADED_FEATURES.include?(p)
        warn "import: skip #{p} (already loaded)" if debug?
        next false
      end
      warn "import: #{p}" if verbose? || debug?
      load p
      $LOADED_FEATURES << p
      true
    end
    loaded.any?
  end
  module_function :import

  def import_up(name = ".loki")
    if name =~ /[*?\[{]/
      dir = Dir.pwd
      loop do
        matches = Dir.glob(File.join(dir, name))
        unless matches.empty?
          warn "import_up: #{name} → #{dir}" if verbose? || debug?
          return matches.map { |p| import(p) }.any?
        end
        parent = File.dirname(dir)
        break if parent == dir
        dir = parent
      end
      warn "import_up: #{name} not found" if debug?
      return false
    end
    path = loki_up(name)
    unless path
      warn "import_up: #{name} not found" if debug?
      return false
    end
    warn "import_up: #{name} → #{path}" if verbose? || debug?
    import path
  end
  module_function :import_up
end
