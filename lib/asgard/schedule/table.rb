# frozen_string_literal: true

module Asgard
  module Schedule
    # The table `asgard schedule list` prints, drawn by tty-table. rows are
    # hashes with :name, :command, :schedule, :state and :last_exit (strings).
    # A cell that doesn't fit wraps onto extra lines; only COMMAND and SCHEDULE
    # give up width, so the short columns always stay whole.
    class Table
      HEADERS      = ["NAME", "COMMAND", "SCHEDULE", "STATE", "LAST EXIT"].freeze
      KEYS         = %i[name command schedule state last_exit].freeze
      FLEXIBLE     = [1, 2].freeze
      MIN_WIDTH    = 14
      PADDING      = 1          # spaces either side of a cell
      EXTRA        = PADDING * 2 # what a column adds to its content

      # Columns available for output: the terminal's when io is one, else
      # $COLUMNS, else a roomy default (piped output shouldn't wrap at 80).
      def self.terminal_width(io = $stdout, env: ENV, default: 120)
        return Integer(env["COLUMNS"], exception: false) || default unless io.tty?

        require "tty-screen"
        TTY::Screen.width
      end

      # rows rendered for the terminal, under title when given: colored when io
      # is a tty and NO_COLOR is unset. headers: relabels the columns; keys:
      # picks them from each row, and flexible: says which give up width
      # first when the table is wider than the screen.
      def self.draw(rows, title: nil, io: $stdout, headers: HEADERS, keys: KEYS, flexible: FLEXIBLE)
        table = new(rows, color: io.tty? && !ENV.key?("NO_COLOR"), width: terminal_width(io), headers:, keys:, flexible:).render
        [title, table].compact.join("\n")
      end

      # color: styles the header, state and last exit with ANSI codes.
      def initialize(rows, color:, width:, headers: HEADERS, keys: KEYS, flexible: FLEXIBLE)
        require "pastel"

        @headers  = headers
        @flexible = flexible
        @styled   = { state: keys.index(:state), last_exit: keys.index(:last_exit) }.compact
        @cells  = rows.map { |row| row.values_at(*keys).map(&:to_s) }
        @pastel = Pastel.new(enabled: color)
        @width  = width
        @column_widths = natural_widths
        shrink_widest while overflowing? && shrinkable?
      end

      def render
        require "tty-table"

        grid = TTY::Table.new(header: @headers.map { |text| @pastel.bold(text) }, rows: @cells.map { |cells| styled(cells) })
        # tty-table gets the content widths and no resize: with resize it
        # re-spreads the columns by its own arithmetic (and squeezes a
        # one-row table), while this way the widths computed here are the
        # widths it draws, wrapping any cell that is longer.
        grid.render(:unicode, multiline: true, resize: false, width: total_width, column_widths: content_widths,
                    padding: [0, PADDING]).to_s
      end

      # Width of each column, padding included. Every column starts at its
      # natural width; when the table would be wider than the screen, the
      # flexible columns give up a character at a time until it fits.
      attr_reader :column_widths

      # Rendered width: the columns plus their borders, one before each
      # column and one after the last.
      def total_width = column_widths.sum + @headers.size + 1

      private

      # The widths without their padding, as tty-table counts them.
      def content_widths = column_widths.map { |width| width - EXTRA }

      def natural_widths = [@headers, *@cells].transpose.map { |column| column.max_by(&:length).length + EXTRA }

      def overflowing? = total_width > @width

      def widest_flexible = @flexible.max_by { |index| @column_widths[index] }

      def shrinkable? = @column_widths[widest_flexible] > MIN_WIDTH

      def shrink_widest = @column_widths[widest_flexible] -= 1

      # The state and last-exit cells colored, wherever keys: put them.
      def styled(cells)
        cells = cells.dup
        @styled.each { |column, index| cells[index] = @pastel.decorate(cells[index], send(:"#{column}_color", cells[index])) }
        cells
      end

      def state_color(state) = { "active" => :green, "running" => :green, "stopped" => :yellow }.fetch(state.split.first, :red)

      def last_exit_color(last_exit) = last_exit.match?(/\A[1-9]\d*\b/) ? :red : :dim
    end
  end
end
