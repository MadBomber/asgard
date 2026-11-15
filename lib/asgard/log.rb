# frozen_string_literal: true

module Asgard
  # Keeps the last M lines of a log, rewriting it in place. Every writer
  # (launchd, systemd's append:, jobs, the watcher) opens its log with
  # O_APPEND, so it keeps writing to the same file at the new end. As with
  # logrotate's copytruncate, a write landing between the last read and the
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

    # Slides the bytes from +offset+ on to the start of +file+, a chunk at a
    # time, then cuts the file after them. Each write lands behind the next
    # read, so no copy is needed, and lines appended meanwhile move too.
    # Signals and Thread#raise wait until the file is cut. A failed read or
    # write still cuts the file after the bytes already moved, so it never
    # holds the tail written over its own head.
    def rewrite(file, offset)
      moved = 0
      Thread.handle_interrupt(Object => :never) do
        while (chunk = read_at(file, offset + moved))
          file.seek(moved)
          file.write(chunk)
          moved += chunk.bytesize
        end
        file.truncate(moved)
      rescue StandardError
        file.truncate(moved) if moved.positive?
        raise
      end
    end

    # Up to CHUNK bytes of +file+ from +position+, or nil at the end.
    def read_at(file, position)
      file.seek(position)
      file.read(CHUNK)
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
