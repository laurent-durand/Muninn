# src/logs/aggregator.cr
# Muninn log aggregator — Crystal.
# Tails /var/log/syslog (or any configured paths), parses structured fields,
# rates error lines, and publishes summaries as JSON.

require "json"
require "time"
require "file_utils"

module Muninn
  module Logs

    LOG_LEVEL_RE = /\b(EMERG|ALERT|CRIT|ERR|ERROR|WARNING|WARN|NOTICE|INFO|DEBUG)\b/i
    KERNEL_OOM   = /Out of memory|oom_kill_process|Killed process/
    DISK_ERR     = /I\/O error|Buffer I\/O error|EXT4-fs error/

    struct LogEntry
      include JSON::Serializable
      property ts       : String
      property host     : String
      property program  : String
      property severity : String
      property message  : String
      property tags     : Array(String)
    end

    struct Summary
      include JSON::Serializable
      property window_secs  : Int32
      property total_lines  : Int64
      property error_count  : Int64
      property warn_count   : Int64
      property oom_events   : Int64
      property disk_errors  : Int64
      property top_programs : Hash(String, Int64)
    end

    class Aggregator
      WINDOW = 60  # summary window in seconds

      @total_lines  = 0_i64
      @error_count  = 0_i64
      @warn_count   = 0_i64
      @oom_events   = 0_i64
      @disk_errors  = 0_i64
      @prog_counts  = Hash(String, Int64).new(0_i64)
      @last_flush   = Time.utc

      def ingest(line : String)
        @total_lines += 1
        entry = parse_line(line)
        return unless entry

        @prog_counts[entry.program] += 1

        case entry.severity.upcase
        when "ERR", "ERROR", "CRIT", "ALERT", "EMERG"
          @error_count += 1
          STDOUT.puts entry.to_json  # forward critical lines immediately
        when "WARNING", "WARN"
          @warn_count += 1
        end

        @oom_events  += 1 if entry.message =~ KERNEL_OOM
        @disk_errors += 1 if entry.message =~ DISK_ERR

        maybe_flush
      end

      private def maybe_flush
        return if (Time.utc - @last_flush).total_seconds < WINDOW
        flush
      end

      def flush
        top = @prog_counts.to_a
          .sort_by { |_, v| -v }
          .first(10)
          .to_h

        summary = Summary.new(
          window_secs:  WINDOW,
          total_lines:  @total_lines,
          error_count:  @error_count,
          warn_count:   @warn_count,
          oom_events:   @oom_events,
          disk_errors:  @disk_errors,
          top_programs: top,
        )
        STDOUT.puts({"type" => "log_summary", "data" => summary}.to_json)
        STDOUT.flush

        @total_lines = @error_count = @warn_count = @oom_events = @disk_errors = 0_i64
        @prog_counts.clear
        @last_flush = Time.utc
      end

      private def parse_line(line : String) : LogEntry?
        # Syslog RFC3164: "Jan  5 12:00:00 hostname program[pid]: message"
        if m = line.match(/^(\w{3}\s+\d+\s+[\d:]+)\s+(\S+)\s+(\S+?)(?:\[\d+\])?:\s+(.*)$/)
          ts, host, prog, msg = m[1], m[2], m[3], m[4]
          sev = (msg.scan(LOG_LEVEL_RE).first?.try(&.[1]) || "INFO").upcase
          tags = [] of String
          tags << "oom"  if msg =~ KERNEL_OOM
          tags << "disk" if msg =~ DISK_ERR
          return LogEntry.new(
            ts: ts, host: host, program: prog,
            severity: sev, message: msg, tags: tags
          )
        end
        nil
      end
    end

    # ── File tailer ───────────────────────────────────────────────────────────

    class Tailer
      def initialize(@path : String, @agg : Aggregator)
      end

      def run
        STDERR.puts "muninn-logs: tailing #{@path}"
        File.open(@path) do |f|
          f.seek(0, IO::Seek::End)   # start at tail
          loop do
            line = f.gets
            if line
              @agg.ingest(line)
            else
              sleep 0.2
            end
          end
        end
      rescue ex
        STDERR.puts "tailer error on #{@path}: #{ex.message}"
      end
    end

  end
end

# ── Entry point ───────────────────────────────────────────────────────────────

paths = ARGV.empty? ? ["/var/log/syslog", "/var/log/kern.log"] : ARGV.to_a
agg   = Muninn::Logs::Aggregator.new

# Tail each file in its own fiber
paths.each do |path|
  next unless File.exists?(path)
  t = Muninn::Logs::Tailer.new(path, agg)
  spawn { t.run }
end

# Also read piped stdin if it's not a tty
unless STDIN.tty?
  spawn do
    STDIN.each_line { |l| agg.ingest(l) }
    agg.flush
  end
end

sleep  # block forever; fibers run on the event loop
