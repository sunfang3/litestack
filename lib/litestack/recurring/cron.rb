# frozen_string_literal: true

module Litestack
  module Recurring
    # Minimal 5-field cron (min hour dom mon dow) without fugit/ActiveSupport.
    # Supports: *, */n, n, n-m, comma lists. DOW 0=Sunday (also 7).
    class Cron
      FIELD_RANGES = {
        min: 0..59,
        hour: 0..23,
        dom: 1..31,
        mon: 1..12,
        dow: 0..7
      }.freeze

      def self.parse(expression)
        new(expression)
      end

      def initialize(expression)
        @source = expression.to_s.strip
        parts = @source.split(/\s+/)
        raise ArgumentError, "cron needs 5 fields: #{expression.inspect}" unless parts.size == 5

        @min = expand(parts[0], :min)
        @hour = expand(parts[1], :hour)
        @dom = expand(parts[2], :dom)
        @mon = expand(parts[3], :mon)
        @dow = expand(parts[4], :dow)
        # Normalize 7 → 0 for Sunday
        @dow = @dow.map { |d| (d == 7) ? 0 : d }.uniq.sort
      end

      attr_reader :source

      def matches?(time)
        t = time.to_time
        @min.include?(t.min) &&
          @hour.include?(t.hour) &&
          @dom.include?(t.day) &&
          @mon.include?(t.month) &&
          @dow.include?(t.wday)
      end

      # Next wall time at or after +from+ (second precision floored to minute).
      def next_after(from = Time.now)
        t = from.to_time
        # Search up to ~2 years of minutes
        cursor = Time.new(t.year, t.month, t.day, t.hour, t.min, 0, t.utc_offset) + 60
        limit = cursor + (366 * 2 * 24 * 3600)
        while cursor < limit
          return cursor if matches?(cursor)

          cursor += 60
        end
        nil
      end

      # Unique key for this schedule slot (used for exactly-once enqueue per minute).
      def slot_key(time)
        t = time.to_time
        format("%04d-%02d-%02dT%02d:%02d", t.year, t.month, t.day, t.hour, t.min)
      end

      private

      def expand(field, name)
        range = FIELD_RANGES.fetch(name)
        return range.to_a if field == "*"

        field.split(",").flat_map { |piece| expand_piece(piece, range) }.uniq.sort
      end

      def expand_piece(piece, range)
        if piece.start_with?("*/")
          step = Integer(piece[2..])
          raise ArgumentError, "invalid step #{piece}" if step <= 0

          range.select { |n| (n % step).zero? }
        elsif piece.include?("-")
          a, b = piece.split("-", 2).map { |x| Integer(x) }
          raise ArgumentError, "invalid range #{piece}" unless range.cover?(a) && range.cover?(b)

          (a..b).to_a
        elsif piece.include?("/")
          base, step_s = piece.split("/", 2)
          step = Integer(step_s)
          nums = expand_piece(base, range)
          nums.select.with_index { |_, i| (i % step).zero? }
        else
          n = Integer(piece)
          if !range.cover?(n) && !(range == (0..7) && n == 7)
            raise ArgumentError, "out of range #{n}"
          end

          [n]
        end
      end
    end
  end
end
