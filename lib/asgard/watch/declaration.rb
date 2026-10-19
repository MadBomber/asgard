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

    # Output and scratch directories a task may write inside the project;
    # always ignored so a task never retriggers itself. Matched against the
    # path relative to the watched directory, at any depth.
    DEFAULT_IGNORES = %w[.git coverage pkg tmp log node_modules].map { |dir| %r{(?:\A|/)#{Regexp.escape(dir)}/} }.freeze

    GLOB_CHARS  = /[*?{]/
    GLOB_TOKENS = %r!\*\*/|\*\*|\*|\?|\{[^}]*\}|\{|[^*?{]+!

    module_function

    # Validates a declaration and returns it as a plain Hash. paths: entries
    # are directories, files or globs relative to the project root; the
    # Hash carries the directories Listen watches and one only: Regexp (or
    # nil) that stands for every pattern. events: picks which kinds of
    # change trigger the task; as: names the entry. Every ArgumentError
    # from the helpers below comes back prefixed with the task.
    def normalize(task, paths:, only: nil, ignore: nil, events: :all, debounce: 0.5, env: {}, as: nil)
      task = task.to_s
      raise ArgumentError, "task name #{task.inspect} must be a single word" unless task.match?(/\A[\w:-]+\z/)

      paths         = relative_paths(paths)
      dirs, matched = watched(paths)
      {
        name:     entry_name(as || task),
        task:,
        paths:,
        dirs:,
        only:     combine_only(matched, regexps(:only, only)),
        ignore:   [*regexps(:ignore, ignore), *DEFAULT_IGNORES],
        events:   normalize_events(events),
        debounce: non_negative_debounce(debounce),
        env:      env.to_h { |key, value| [key.to_s, value.to_s] }
      }
    rescue ArgumentError => e
      raise ArgumentError, "watch :#{task} #{e.message}"
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

    # [directories, patterns] for a declaration's paths. A bare directory
    # takes everything beneath it, so it cannot share a declaration with a
    # pattern or a file: Listen applies one only: filter to every directory
    # it watches, and the pattern would silently filter the directory too.
    def watched(paths)
      splits   = paths.map { |path| split_glob(path) }
      patterns = splits.filter_map(&:last)
      if !patterns.empty? && patterns.size < splits.size
        raise ArgumentError,
              "mixes a bare directory with patterns or files, which would filter the directory too; " \
              "declare them separately or write the directory as dir/**/*"
      end

      [splits.map(&:first).uniq, patterns]
    end

    # [directory, Regexp or nil] for one paths: entry.
    #   "lib/**/*.rb"   => ["lib", /\A(?:.*\/)?[^\/]*\.rb\z/]
    #   "lib/asgard.rb" => ["lib", /\Aasgard\.rb\z/]
    #   "docs"          => ["docs", nil]
    # The Regexp is matched against the path relative to the directory,
    # which is how Listen applies only:. A plain path names a file when
    # stat (File, or a stand-in in tests) finds one there or when it has
    # an extension, so a file that does not exist yet can be watched.
    def split_glob(path, stat: File)
      segments = path.delete_suffix("/").split("/")
      first    = segments.index { |segment| segment.match?(GLOB_CHARS) }
      return [directory(segments[0...first]), glob_regexp(segments[first..].join("/"))] if first

      *parents, last = segments
      last = last.to_s
      return [directory(segments), nil] unless stat.file?(path) || !File.extname(last).empty?

      [directory(parents), /\A#{Regexp.escape(last)}\z/]
    end

    def directory(segments) = segments.empty? ? "." : segments.join("/")

    # The Regexp a glob matches, shell-style: ** spans directories, * and ?
    # stay within one, {a,b} is an alternative. Anything else is literal.
    def glob_regexp(pattern)
      body = pattern.scan(GLOB_TOKENS).map { |token| glob_token(token) }.join
      /\A#{body}\z/
    end

    def glob_token(token)
      case token
      when "**/" then "(?:.*/)?"
      when "**"  then ".*"
      when "*"   then "[^/]*"
      when "?"   then "[^/]"
      when /\A\{(.*)\}\z/ then "(?:#{Regexp.last_match(1).split(',', -1).map { |alt| Regexp.escape(alt) }.join('|')})"
      else Regexp.escape(token)
      end
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
