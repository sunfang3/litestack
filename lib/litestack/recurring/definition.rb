# frozen_string_literal: true

require_relative "cron"

module Litestack
  module Recurring
    # One recurring task definition loaded from YAML / Hash.
    #
    # Solid Queue–inspired keys:
    #   class: "MyJob"           # required (or command:)
    #   args: [1, {foo: "bar"}]  # optional
    #   queue: default
    #   schedule: "*/5 * * * *"  # cron
    #   every: 300               # seconds (alternative to schedule)
    #   schedule: every 5 minutes  # simple English (subset)
    #   command: "..."           # optional eval (Rails apps)
    #   enabled: true
    class Definition
      attr_reader :name, :klass, :args, :queue, :command, :enabled, :schedule_source

      def self.from_hash(name, hash)
        h = (hash || {}).transform_keys { |k| k.to_s }
        new(
          name: name.to_s,
          klass: h["class"] || h["job_class"],
          args: h["args"] || [],
          queue: (h["queue"] || "default").to_s,
          command: h["command"],
          schedule: h["schedule"],
          every: h["every"] || h["interval"],
          enabled: h.key?("enabled") ? !!h["enabled"] : true
        )
      end

      def initialize(name:, klass: nil, args: [], queue: "default", command: nil,
        schedule: nil, every: nil, enabled: true)
        @name = name.to_s
        @klass = klass&.to_s
        @args = Array(args)
        @queue = queue.to_s
        @command = command
        @enabled = enabled
        @schedule_source = schedule || every
        @cron = nil
        @every_s = nil

        if every && !schedule
          @every_s = Integer(every)
          raise ArgumentError, "every must be > 0" if @every_s <= 0
        elsif schedule
          parse_schedule(schedule)
        else
          raise ArgumentError, "recurring #{@name}: need schedule: or every:"
        end

        if @klass.to_s.empty? && @command.to_s.empty?
          raise ArgumentError, "recurring #{@name}: need class: or command:"
        end
      end

      def interval?
        !@every_s.nil?
      end

      def due?(now, last_enqueued_at, last_key)
        return false unless @enabled

        if interval?
          return true if last_enqueued_at.nil?

          (now.to_f - last_enqueued_at.to_f) >= @every_s
        else
          return false unless @cron.matches?(now)

          key = @cron.slot_key(now)
          last_key != key
        end
      end

      def slot_key(now)
        if interval?
          # Bucket by interval start so multi-process ticks don't double-fire.
          bucket = (now.to_i / @every_s) * @every_s
          "every:#{@every_s}:#{bucket}"
        else
          @cron.slot_key(now)
        end
      end

      def describe
        if interval?
          "every #{@every_s}s"
        else
          "cron #{@cron.source}"
        end
      end

      private

      def parse_schedule(raw)
        s = raw.to_s.strip
        if s.include?("*") || s.match?(/\A[\d,\-\/\s]+\z/)
          @cron = Cron.parse(s)
          return
        end

        # Simple English subset (no fugit)
        case s.downcase
        when /\Aevery\s+(\d+)\s+seconds?\z/
          @every_s = Integer(Regexp.last_match(1))
        when /\Aevery\s+(\d+)\s+minutes?\z/
          @every_s = Integer(Regexp.last_match(1)) * 60
        when /\Aevery\s+(\d+)\s+hours?\z/
          @every_s = Integer(Regexp.last_match(1)) * 3600
        when "every minute"
          @every_s = 60
        when "every hour"
          @cron = Cron.parse("0 * * * *")
        when "every day", "daily"
          @cron = Cron.parse("0 0 * * *")
        when /\Aevery day at (\d{1,2}):(\d{2})\z/
          h = Integer(Regexp.last_match(1))
          m = Integer(Regexp.last_match(2))
          @cron = Cron.parse("#{m} #{h} * * *")
        when /\Aevery hour at minute (\d{1,2})\z/
          m = Integer(Regexp.last_match(1))
          @cron = Cron.parse("#{m} * * * *")
        else
          raise ArgumentError, "unsupported schedule #{raw.inspect} (use cron or every N minutes)"
        end
      end
    end
  end
end
