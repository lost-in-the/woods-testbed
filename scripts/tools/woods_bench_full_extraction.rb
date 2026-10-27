# frozen_string_literal: true

# Child of scripts/tools/woods_bench.rb. Run by it as
#
#   bin/rails runner script/shared/tools/woods_bench_full_extraction.rb
#
# when a scenario edits a path whose change invalidates boot-captured state
# (db/schema.rb: the schema cache and column information a Rails process
# captures once). The gem refuses `extract_changed` over such a path, and a
# full extraction in the bench's own process would reuse the state that
# process captured before the edit. This process does one full extraction into
# WOODS_OUTPUT, times it around `extract_all` alone (its own boot is already
# over), parses the gem's WOODS_PROFILE phase lines exactly as the bench does,
# and prints one marker-prefixed JSON line that the bench reads back. Nothing
# else is written to stdout by this file; the bench takes the last marker line.

require 'json'
require 'woods'
require 'woods/extractor'

require_relative '../support/woods_phase_logger'

MARKER = 'WOODS_BENCH_FULL_EXTRACTION '

def child_rss_mb
  line = File.read('/proc/self/status').lines.find { |l| l.start_with?('VmRSS:') }
  line ? (line.split[1].to_i / 1024.0).round(1) : nil
rescue StandardError
  nil
end

index_dir = ENV.fetch('WOODS_OUTPUT')
logger = PhaseLogger.new
Rails.logger = logger
ENV['WOODS_PROFILE'] = '1'

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = Woods::Extractor.new(output_dir: index_dir).extract_all
finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# extract_all returns a per-type Hash of units; count them the way the bench
# counts an incremental run's flat `touched` list.
units_written = result.is_a?(Hash) ? result.values.sum { |units| Array(units).size } : Array(result).size

report = {
  'wall_ms' => ((finished - started) * 1000).round(1),
  'phases_ms' => logger.phase_durations(started, finished),
  'profile_total_ms' => logger.profile_total_ms,
  'profile_lines' => logger.profile_lines,
  'units_written' => units_written,
  'rss_mb' => child_rss_mb
}

$stdout.puts "#{MARKER}#{JSON.generate(report)}"
$stdout.flush
