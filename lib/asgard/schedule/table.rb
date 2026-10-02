# frozen_string_literal: true

module Asgard
  module Schedule
    # The table `asgard schedule list` prints, drawn by tty-table. rows are
    # hashes with :name, :command, :schedule, :state and :last_exit (strings).
    # A cell that doesn't fit wraps onto extra lines; only COMMAND and SCHEDULE
    # give up width, so the short columns always stay whole.
    class Table
      HEADERS      = ["NAME", "COMMAND", "SCHEDULE", "STATE", "LAST EXIT"].freeze
      FLEXIBLE     = [1, 2].freeze
      MIN_WIDTH    = 14
      EXTRA        = 4 # a space either side of a cell, plus slack for tty-table's rounding
      BORDERS      = HEADERS.size + 1 # one before each column and one after the last

      # Columns available for output: the terminal's when io is one, else
      # $COLUMNS, else a roomy default (piped output shouldn't wrap at 80).
      def self.terminal_width(io = $stdout, env: ENV, default: 120)
        return Integer(env["COLUMNS"], exception: false) || default unless io.tty?

        require "tty-screen"
        TTY::Screen.width
      end

      # rows rendered for the terminal, under title when given: colored when io
      # is a tty and NO_COLOR is unset.
      def self.draw(rows, title: nil, io: $stdout)
        table = new(rows, color: io.tty? && !ENV.key?("NO_COLOR"), width: terminal_width(io)).render
        [title, table].compact.join("\n")
      end

      # color: styles the header, state and last exit with ANSI codes.
      def initialize(rows, color:, width:)
        require "pastel"

        @cells  = rows.map { |row| row.values_at(:name, :command, :schedule, :state, :last_exit) }
        @pastel = Pastel.new(enabled: color)
        @width  = width
        @column_widths = natural_widths
        shrink_widest while overflowing? && shrinkable?
      end

      def render
        require "tty-table"

        grid = TTY::Table.new(header: HEADERS.map { |text| @pastel.bold(text) }, rows: @cells.map { |cells| styled(cells) })
        grid.render(:unicode, multiline: true, resize: true, width: total_width, column_widths:, padding: [0, 1]).to_s
      end

      # Width of each column, padding included. Every column starts at its
      # natural width; when the table would be wider than the screen, the
      # flexible columns give up a character at a time until it fits.
      attr_reader :column_widths

      # Rendered width: the columns plus their borders.
      def total_width = column_widths.sum + BORDERS

      private

      def natural_widths = [HEADERS, *@cells].transpose.map { |column| column.max_by(&:length).length + EXTRA }

      def overflowing? = total_width > @width

      def widest_flexible = FLEXIBLE.max_by { |index| @column_widths[index] }

      def shrinkable? = @column_widths[widest_flexible] > MIN_WIDTH

      def shrink_widest = @column_widths[widest_flexible] -= 1

      def styled(cells)
        *lead, state, last_exit = cells
        state_color = { "active" => :green, "stopped" => :yellow }.fetch(state, :red)
        exit_color  = last_exit.match?(/\A[1-9]\d*\z/) ? :red : :dim
        [*lead, @pastel.decorate(state, state_color), @pastel.decorate(last_exit, exit_color)]
      end
    end
  end
end
