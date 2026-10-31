# frozen_string_literal: true

module Asgard
  module Schedule
    # Reading back the job files a backend writes, the same way for
    # launchd plists and systemd units. Pure apart from reading the files.
    module JobFiles
      module_function

      # [[project_slug, name], ...], sorted, for each job file in +dir+.
      def entries_in(dir, prefix:, ext:) = entries(Dir.glob(File.join(dir, "#{prefix}.*#{ext}")), prefix:, ext:)

      # [[project_slug, name], ...], sorted, for each of +paths+ named
      # <prefix>.<project_slug>.<name><ext>; any other file name is skipped.
      def entries(paths, prefix:, ext:)
        paths.map { File.basename(it, ext).delete_prefix("#{prefix}.").split(".", 2) }.select { it.size == 2 }.sort
      end

      # The project root +parser+ reads from the job file at +path+, or nil
      # when there is no such file.
      def directory(path, parser) = File.exist?(path) ? parser.call(File.read(path)) : nil
    end
  end
end
