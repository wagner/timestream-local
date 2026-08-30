# frozen_string_literal: true

module TimestreamLocal
  # Verbose mode: a running account of what the server is doing, on stdout.
  #
  # Off by default. A local emulator that narrates every request is noise right
  # up to the moment a query comes back empty and the question is what SQLite
  # was actually asked -- so the interesting line is the rewritten statement,
  # and it is never truncated.
  #
  # Turn it on with TIMESTREAM_LOCAL_VERBOSE=true, or `bin/timestream-local
  # --verbose`.
  #
  # Lines are `[timestream-local] time event key=value ...` and are written
  # whole under a mutex: scheduled-query runs happen on their own threads, so
  # half-interleaved lines are a real possibility rather than a theoretical one.
  module Log
    PREFIX = "[timestream-local]"
    # Values that are already a single bare token are printed as-is; anything
    # else is quoted, so a field with spaces cannot be read as two fields.
    BARE_VALUE_RE = %r{\A[\w.:/@=+-]+\z}

    class << self
      attr_writer :enabled, :io

      def enabled?
        return @enabled if defined?(@enabled)

        ENV.fetch("TIMESTREAM_LOCAL_VERBOSE", "false") == "true"
      end

      def io
        @io ||= $stdout
      end

      # Fields that are nil are dropped, so callers can pass a value that is
      # only sometimes there without branching around it.
      def event(name, **fields)
        return unless enabled?

        write("#{PREFIX} #{timestamp} #{name}#{format_fields(fields)}\n")
      end

      # Paired with `elapsed_ms` to fill in an event's `ms=`.
      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started)
        ((now - started) * 1000).round
      end

      private

      def write(line)
        mutex.synchronize do
          io.write(line)
          io.flush
        end
      rescue IOError, Errno::EPIPE
        # Logging is never the reason the server falls over.
        nil
      end

      def mutex
        @mutex ||= Mutex.new
      end

      def timestamp
        Time.now.strftime("%H:%M:%S.%L")
      end

      def format_fields(fields)
        fields.compact.map { |key, value| " #{key}=#{format_value(value)}" }.join
      end

      # Newlines are folded so that one event stays one line -- a multi-line SQL
      # statement is still the whole statement, just on a single line.
      def format_value(value)
        text = value.to_s.gsub(/\s+/, " ").strip
        text.match?(BARE_VALUE_RE) ? text : text.inspect
      end
    end
  end
end
