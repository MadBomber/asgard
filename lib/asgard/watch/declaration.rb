# frozen_string_literal: true

module Asgard
  # The platform-neutral half of the watcher: validates `watch` declarations
  # and turns their paths into what Listen needs (directories to watch plus
  # only:/ignore: filters). Everything here is pure, so each method can be
  # tested on its own.
  module Watch
    # The kinds of change a declaration can react to. Listen calls the first
    # one "modified"; that name is accepted as an alias.
    EVENTS        = %i[changed added removed].freeze
    EVENT_ALIASES = { modified: :changed }.freeze

    # Version-control and dependency directories, ignored at any depth.
    # Each matches the bare directory too ("app/node_modules"), which is
    # what Listen tests while it scans, so the tree beneath is never walked.
    DEFAULT_IGNORES = %w[.git .hg .svn node_modules].map { |dir| %r{(?:\A|/)#{Regexp.escape(dir)}(?:/|\z)} }.freeze

    # Output and scratch directories a task or Bundler writes in the
    # project root, ignored so a task never retriggers itself. Only the
    # root's own: an app/log/ of yours is watched like any directory.
    ROOT_IGNORES = %w[coverage pkg tmp log .bundle bundle vendor/bundle vendor/ruby]
                   .map { |dir| %r{\A#{Regexp.escape(dir)}(?:/|\z)} }.freeze

    GLOB_CHARS  = /[*?{\[]/
    BRACE_DEPTH = Hash.new(0).update("{" => 1, "}" => -1).freeze
    GLOB_TOKENS = %r~\*\*/|\*\*|\*|\?|(?<brace>\{(?:[^{}]|\g<brace>)*\})|\[!?[^\]/]+\]|\{|\[|[^*?{\[]+~

    module_function

    # Validates a declaration and returns it as a plain Hash. paths: entries
    # are directories, files or globs relative to the project root; the
    # Hash carries the directories Listen watches, and per directory the
    # only: Regexp (or nil) for its own patterns and its ignore: list.
    # events: picks which kinds of change trigger the task; as: names the
    # entry. Every ArgumentError from the helpers below comes back
    # prefixed with the task.
    def normalize(task, paths:, only: nil, ignore: nil, events: :all, debounce: 0.5, env: {}, as: nil)
      task = task.to_s
      raise ArgumentError, "task name #{task.inspect} must be a single word" unless task.match?(/\A[\w:-]+\z/)

      paths   = relative_paths(paths)
      globs   = watched(paths)
      filters = regexps(:only, only)
      ignores = regexps(:ignore, ignore)
      {
        name:     entry_name(as || task),
        task:,
        paths:,
        dirs:     globs.keys,
        only:     globs.to_h { |dir, patterns| [dir, combine_only(patterns.map { |pattern| glob_regexp(pattern) }, filters)] },
        ignore:   globs.keys.to_h { |dir| [dir, ignores_for(dir, ignores)] },
        events:   normalize_events(events),
        debounce: non_negative_debounce(debounce),
        env:      environment(env)
      }
    rescue ArgumentError => e
      raise ArgumentError, "watch :#{task} #{e.message}"
    end

    # The ignore: list Listen gets for one watched directory: the
    # declared ones, DEFAULT_IGNORES, and ROOT_IGNORES when the directory
    # is the project root.
    def ignores_for(dir, declared) = [*declared, *DEFAULT_IGNORES, *(dir == "." ? ROOT_IGNORES : [])]

    # env: as a Hash of String names to String values, refused here when
    # Process.spawn would refuse it later: a name that is empty, not a
    # String or Symbol, or holds = or a NUL byte; a value holding a NUL.
    def environment(env)
      raise ArgumentError, "env: expects a Hash (got #{env.inspect})" unless env.is_a?(Hash)

      env.to_h { |key, value| env_pair(key, value) }
    end

    def env_pair(key, value)
      name = key.to_s if key.is_a?(String) || key.is_a?(Symbol)
      raise ArgumentError, "env: #{key.inspect} is not a variable name" if name.nil? || name.empty? || name.match?(/[=\0]/)

      value = value.to_s
      raise ArgumentError, "env: the value of #{name} holds a NUL byte" if value.include?("\0")

      [name, value]
    end

    # The entry name (as:, or the task), checked for the characters a file
    # or label can carry.
    def entry_name(name)
      name = name.to_s
      raise ArgumentError, "as: #{name.inspect} may only contain letters, digits, _ . -" unless name.match?(/\A[\w.-]+\z/)

      name
    end

    # paths: as a non-empty Array of relative, non-empty Strings.
    def relative_paths(paths)
      paths = Array(paths).map(&:to_s)
      raise ArgumentError, "needs at least one path" if paths.empty?

      bad = paths.find { |path| path.empty? || File.absolute_path?(path) }
      raise ArgumentError, "paths are relative to the project root (got #{bad.inspect})" if bad

      paths
    end

    # { directory => its glob patterns } for a declaration's paths, each
    # directory listened to on its own so its patterns never filter
    # another's. A bare directory takes everything beneath it (no
    # patterns), so it cannot share a declaration with a pattern or a
    # file: the pattern would silently filter the directory too.
    def watched(paths)
      root   = declaration_root
      splits = paths.map { |path| split_path(path, root:) }
      globs  = splits.filter_map(&:last)
      if !globs.empty? && globs.size < splits.size
        raise ArgumentError,
              "mixes a bare directory with patterns or files, which would filter the directory too; " \
              "declare them separately or write the directory as dir/**/*"
      end

      fold(splits)
    end

    # Groups [directory, pattern or nil] pairs by directory. A directory
    # inside another of the same declaration folds into the outer one,
    # its pattern prefixed with the path between them, so a change is
    # reported once rather than by two listeners.
    def fold(splits)
      dirs = splits.map(&:first).uniq
      splits.each_with_object({}) do |(dir, pattern), grouped|
        outer = dirs.select { |other| inside?(dir, other) }.min_by(&:size)
        list  = grouped[outer] ||= []
        list << rebase(pattern, dir, outer) if pattern
      end
    end

    # Whether +dir+ is +other+ or lies beneath it.
    def inside?(dir, other) = other == dir || other == "." || dir.start_with?("#{other}/")

    # +pattern+ (relative to +dir+) made relative to +outer+, which holds dir.
    def rebase(pattern, dir, outer)
      return pattern if dir == outer

      "#{outer == '.' ? dir : dir.delete_prefix("#{outer}/")}/#{pattern}"
    end

    # [directory, Regexp or nil] for one paths: entry (see split_path).
    #   "lib/**/*.rb"   => ["lib", /\A(?:.*\/)?[^\/]*\.rb\z/]
    #   "lib/asgard.rb" => ["lib", /\Aasgard\.rb\z/]
    #   "docs"          => ["docs", nil]
    # The Regexp is matched against the path relative to the directory,
    # which is how Listen applies only:.
    def split_glob(path, stat: File, root: Dir.pwd)
      dir, pattern = split_path(path, stat:, root:)
      [dir, pattern && glob_regexp(pattern)]
    end

    # [directory, glob pattern relative to it, or nil] for one paths:
    # entry; "." and empty segments are dropped. A plain path is looked
    # up under +root+ (the project root, wherever asgard runs from) with
    # stat (File, or a stand-in in tests): a directory there is a
    # directory, dots and all; otherwise it names a file when one is
    # there, when it has an extension, or when it is a dotfile (.env), so
    # a file that does not exist yet can be watched.
    def split_path(path, stat: File, root: Dir.pwd)
      segments = path.split("/").reject { |segment| segment.empty? || segment == "." }
      first    = segments.index { |segment| segment.match?(GLOB_CHARS) }
      return [directory(segments[0...first]), segments[first..].join("/")] if first

      *parents, last = segments
      full = File.expand_path(path, root)
      return [directory(segments), nil] if last.nil? || stat.directory?(full) || !file_name?(last, full, stat)

      [directory(parents), last]
    end

    def file_name?(name, full, stat) = stat.file?(full) || !File.extname(name).empty? || name.start_with?(".")

    # Where plain paths are looked up: the directory of the nearest .loki,
    # or the current directory without one.
    def declaration_root = (loki_up&.dirname || Dir.pwd).to_s

    def directory(segments) = segments.empty? ? "." : segments.join("/")

    # The Regexp a glob matches, shell-style: ** spans directories, * and ?
    # stay within one, {a,b} is an alternative (nested braces too), [ab]
    # and [!ab] are character classes. Anything else, an unclosed { or [
    # included, is literal.
    def glob_regexp(pattern) = /\A#{glob_body(pattern)}\z/

    def glob_body(pattern) = pattern.gsub(GLOB_TOKENS) { |token| glob_token(token) }

    def glob_token(token)
      case token
      when "**/" then "(?:.*/)?"
      when "**"  then ".*"
      when "*"   then "[^/]*"
      when "?"   then "[^/]"
      when /\A\{(.*)\}\z/m then "(?:#{brace_alternatives(Regexp.last_match(1)).map { |alt| glob_body(alt) }.join('|')})"
      when /\A\[(.+)\]\z/m then char_class(Regexp.last_match(1))
      else Regexp.escape(token)
      end
    end

    # The comma-separated alternatives of a brace's body, splitting only
    # at commas outside any nested brace: "a,{b,c}" => ["a", "{b,c}"].
    def brace_alternatives(body)
      depth = 0
      body.each_char.with_object([+""]) do |char, parts|
        depth += BRACE_DEPTH[char]
        char == "," && depth.zero? ? parts << +"" : parts.last << char
      end
    end

    # A glob character class body ("ab", "!a", "a-c") as a Regexp class
    # that never matches the directory separator.
    def char_class(body)
      negated = body.size > 1 && body.start_with?("!", "^")
      body    = body[1..] if negated
      "(?!/)[#{'^' if negated}#{body.gsub(/[\\\[\]^&]/) { |char| "\\#{char}" }}]"
    end

    # One only: Regexp (or nil for no filter) from the patterns the paths
    # produced and the declared only:. Within each group any may match;
    # when both groups are present a path must satisfy one from each.
    def combine_only(patterns, only)
      any_pattern = patterns.empty? ? nil : Regexp.union(patterns)
      any_only    = only.empty? ? nil : Regexp.union(only)
      return any_pattern || any_only unless any_pattern && any_only

      /(?=#{any_pattern})(?=.*?(?:#{any_only}))/
    end

    # only:/ignore: as an Array of Regexps.
    def regexps(option, value)
      list = Array(value)
      bad  = list.find { |item| !item.is_a?(Regexp) }
      raise ArgumentError, "#{option}: expects a Regexp or an Array of them (got #{bad.inspect})" if bad

      list
    end

    # events: as a frozen Set of EVENTS. :all expands to every kind;
    # :modified means :changed.
    def normalize_events(value)
      list    = Array(value).map { |event| event_name(event) }
      unknown = list - EVENTS - [:all]
      raise ArgumentError, "events: unknown #{unknown.first.inspect}; use :changed, :added, :removed or :all" unless unknown.empty?

      list = EVENTS if list.include?(:all)
      raise ArgumentError, "events: must name at least one of :changed, :added, :removed" if list.empty?

      Set.new(list).freeze
    end

    def event_name(event)
      name = event.to_sym
      EVENT_ALIASES.fetch(name) { name }
    end

    def non_negative_debounce(debounce)
      unless debounce.is_a?(Numeric) && !debounce.negative?
        raise ArgumentError, "debounce: must be a number of seconds, zero or more (got #{debounce.inspect})"
      end

      debounce
    end
  end
end
