# frozen_string_literal: true

require "tempfile"

module Asgard
  # Keeps the last M lines of a log, rewriting it in place. Every writer
  # (launchd, systemd's append:, jobs, the watcher) opens its log with
  # O_APPEND, so it keeps writing to the same file at the new end. As with
  # logrotate's copytruncate, a write landing between the copy and the
  # truncate can be lost.
  module Log
    CHUNK = 64 * 1024

    module_function

    def line_count(value)
      raise ArgumentError, "--lines must be a nonnegative integer" unless value.to_s.match?(/\A[0-9]+\z/)

      Integer(value.to_s, 10)
    end

    # The byte offset where the last +lines+ lines of +io+ begin. Scans
    # backwards in bounded chunks; a final newline ends the last line
    # rather than starting an empty one.
    def tail_offset(io, lines)
      position = io.size
      return position if lines.zero? || position.zero?

      io.seek(-1, IO::SEEK_END)
      remaining = lines + (io.read(1) == "\n" ? 1 : 0)
      while position.positive?
        length = [position, CHUNK].min
        position -= length
        io.seek(position)
        chunk = io.read(length)
        index = chunk.bytesize
        while index.positive? && (index = chunk.rindex("\n", index - 1))
          remaining -= 1
          return position + index + 1 if remaining.zero?
        end
      end
      0
    end

    # Bytes removed (or that would be, with +dry_run+).
    def truncate(path, lines:, dry_run: false)
      File.open(path, dry_run ? "rb" : "r+b") do |file|
        offset = tail_offset(file, lines)
        rewrite(file, offset) unless dry_run || offset.zero?
        offset
      end
    end

    def rewrite(file, offset)
      Tempfile.create("asgard-log", binmode: true) do |tail|
        file.seek(offset)
        IO.copy_stream(file, tail)
        tail.rewind
        file.rewind
        IO.copy_stream(tail, file)
        file.truncate(tail.size)
      end
    end

    def truncate_logs(paths, lines:, dry_run: false, out: $stdout)
      count = line_count(lines)
      found = paths.select { |path| File.file?(path) }.uniq.sort
      return out.puts("No logs found for this project.") if found.empty?

      found.each do |path|
        bytes = truncate(path, lines: count, dry_run:)
        out.puts "#{dry_run ? 'would truncate' : 'truncated'} #{path}: #{bytes} bytes #{dry_run ? 'would be removed' : 'removed'}"
      end
    end
  end
end
