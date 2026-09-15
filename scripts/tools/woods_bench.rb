# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/tools/woods_bench.rb
#
# Lives in scripts/tools/ rather than scripts/ deliberately: CI runs every
# scripts/*.rb against every variant, and this one is slow and MUTATES app
# files. Only idempotent, read-only, version-agnostic smoke scripts belong one
# level up.
#
# ═══════════════════════════════════════════════════════════════════════════
# What this measures
# ═══════════════════════════════════════════════════════════════════════════
#
# The three claims that lost-in-the/woods `docs/WATCH_DAEMON.md` currently
# documents as *extrapolated*, because every host available when they were
# written was small (woods-testbed#2):
#
#   1. Incremental latency at scale — p50/p95 for a one-file change against an
#      app with thousands of units, where payload seeding and other fixed work
#      can dominate a small change.
#   2. Whole-app re-run cost (#165 review finding 16) — a routes change replaces
#      every ROUTE_CONSUMER_EXTRACTORS type wholesale. The reviewer measured
#      1,707 units / 24% of their index; on a fixture app the same change is a
#      rounding error, so any optimisation is unfalsifiable there.
#   3. Per-daemon memory — RSS after N cycles.
#
# ═══════════════════════════════════════════════════════════════════════════
# How to run
# ═══════════════════════════════════════════════════════════════════════════
#
#   # generate a tree first — the point is scale
#   ruby script/shared/tools/generate_large_app.rb          # WOODS_GEN_SCALE=small|medium|large
#   bin/rails db:prepare
#   bin/rails runner script/shared/tools/woods_bench.rb
#
#   WOODS_BENCH_REPS=7          repetitions per scenario (default 7; p95 of 7 is
#                               the 7th value, so treat p95 as indicative below
#                               ~20 reps and say so in the output)
#   WOODS_BENCH_JSON=path       also write the JSON payload to a file
#   WOODS_BENCH_SCENARIOS=a,b   restrict to named scenarios
#
# ═══════════════════════════════════════════════════════════════════════════
# What "good" looks like
# ═══════════════════════════════════════════════════════════════════════════
#
# Deliberately no thresholds. Hardware varies far too much between a laptop and
# a shared CI runner for a pass/fail number to mean anything, and a benchmark
# that fails spuriously gets muted. CI gates on *completion*; the numbers are
# for humans and for the gem's docs.
#
# Every result embeds the generator manifest (version, seed, scale, tree
# checksum), the Rails/Ruby versions and the gem SHA, so a stored number stays
# interpretable rather than becoming folklore.

require 'json'
require 'benchmark'
require 'open3'
require 'woods/generation'

APP        = Rails.root
INDEX_DIR  = Pathname.new(ENV.fetch('WOODS_OUTPUT', APP.join('tmp/woods').to_s))
REPS       = Integer(ENV.fetch('WOODS_BENCH_REPS', '7'))
CHANGE_DIR = APP.join('script/shared/tools/bench_changes')

require 'woods'
require 'woods/extractor'

require_relative '../support/woods_phase_logger'

# Extraction wall time excludes Rails boot and mutation/reload setup. Raw
# profile lines retain the evidence behind the parsed, additive phase totals.
def profile_extraction
  logger = PhaseLogger.new
  original_logger = Rails.logger
  original_profile = ENV['WOODS_PROFILE']
  Rails.logger = logger
  ENV['WOODS_PROFILE'] = '1'
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  [result, { wall_ms: ((finished - started) * 1000).round(1),
             phases: logger.phase_durations(started, finished),
             profile_total_ms: logger.profile_total_ms, profile_lines: logger.profile_lines }]
ensure
  Rails.logger = original_logger if original_logger
  ENV['WOODS_PROFILE'] = original_profile
end

def rss_mb
  line = File.read('/proc/self/status').lines.find { |l| l.start_with?('VmRSS:') }
  line ? (line.split[1].to_i / 1024.0).round(1) : nil
rescue StandardError
  nil
end

def read_json(path)
  JSON.parse(File.read(path, encoding: 'UTF-8'))
rescue StandardError
  nil
end

def current_manifest
  read_json(Woods::Generation.new(output_dir: INDEX_DIR).payload_dir.join('manifest.json')) || {}
end

def percentile(sorted, fraction)
  return nil if sorted.empty?

  index = ((sorted.size - 1) * fraction).round
  sorted[index]
end

def load_scenarios
  wanted = ENV['WOODS_BENCH_SCENARIOS']&.split(',')&.map(&:strip)

  Dir[CHANGE_DIR.join('*.rb')].sort.filter_map do |file|
    spec = eval(File.read(file), TOPLEVEL_BINDING, file) # rubocop:disable Security/Eval
    next if wanted && !wanted.include?(spec[:name])

    spec.merge(file: File.basename(file))
  end
end

# ── Cold full extraction ──────────────────────────────────────────────────
# Start without a prior payload so this measures a cold full extraction.
# Repeat-full seeding needs its own scenario; do not infer it from this run.
def cold_full_extraction
  FileUtils.rm_rf(INDEX_DIR)

  _result, measurement = profile_extraction do
    Woods::Extractor.new(output_dir: INDEX_DIR).extract_all
  end
  measurement
end

# One incremental cycle over a real edit, applied and reverted so the tree ends
# where it started and every repetition measures the same change.
def incremental_cycle(spec)
  path = APP.join(spec[:path])
  original = path.read
  mutated = spec[:apply].call(original)

  raise "change script #{spec[:file]} did not modify #{spec[:path]} — its anchor has drifted" if mutated == original

  path.write(mutated)
  Rails.application.reloader.reload!

  before = current_manifest&.fetch('total_units', nil)

  extractor = Woods::Extractor.new(output_dir: INDEX_DIR)
  results, measurement = profile_extraction { extractor.extract_changed([path.to_s]) }

  # extract_changed returns `touched.to_a` — a flat Array of unit identifiers,
  # NOT a Hash keyed by type the way extract_all's result is. Treating it as a
  # Hash silently reports 0 units written for every scenario, which is precisely
  # the number finding 16 needs.
  touched = Array(results).size
  after = current_manifest&.fetch('total_units', nil)

  { ms: measurement[:wall_ms], phases_ms: measurement[:phases],
    profile_total_ms: measurement[:profile_total_ms], profile_lines: measurement[:profile_lines],
    units_written: touched, index_before: before, index_after: after, rss_mb: rss_mb }
ensure
  if original
    path.write(original)
    Rails.application.reloader.reload!
    Woods::Extractor.new(output_dir: INDEX_DIR).extract_changed([path.to_s])
  end
end

# ── Run ───────────────────────────────────────────────────────────────────
scenarios = load_scenarios
abort "no change scripts found under #{CHANGE_DIR}" if scenarios.empty?

puts '=== woods_bench ==='
puts "variant:   #{Rails.application.class.module_parent_name} (#{APP})"
puts "rails:     #{Rails.version}   ruby: #{RUBY_VERSION}"
puts "reps:      #{REPS} per scenario"
puts

generated = read_json(APP.join('tmp/generated_manifest.json'))
puts generated ? "generated: scale=#{generated['scale']} families=#{generated['families']} tree=#{generated['tree_sha256'][0, 16]}" : 'generated: none (kernel only)'

rss_start = rss_mb
puts "rss before: #{rss_start} MB"
puts

print 'cold full extraction... '
cold = cold_full_extraction
puts "#{cold[:wall_ms]} ms"

manifest = current_manifest || {}
counts = manifest['counts'] || {}
total_units = manifest['total_units'].to_i
app_units = total_units - counts.fetch('rails_source', 0).to_i

puts "  index: #{total_units} units (#{app_units} app-code, #{counts.fetch('rails_source', 0)} rails_source)"
puts

results = scenarios.map do |spec|
  print "#{spec[:name].ljust(12)} "
  samples = REPS.times.map { incremental_cycle(spec) }
  times = samples.map { |s| s[:ms] }.sort
  written = samples.map { |s| s[:units_written] }.max

  row = {
    'name' => spec[:name],
    'description' => spec[:description],
    'path' => spec[:path],
    'reps' => REPS,
    'min_ms' => times.first,
    'p50_ms' => percentile(times, 0.5),
    'p95_ms' => percentile(times, 0.95),
    'max_ms' => times.last,
    'units_written_max' => written,
    'units_written_pct_of_index' => total_units.positive? ? ((written.to_f / total_units) * 100).round(1) : nil,
    'rss_mb_after' => samples.last[:rss_mb],
    'samples' => samples
  }
  puts "p50 #{row['p50_ms']} ms  p95 #{row['p95_ms']} ms  wrote #{written} units (#{row['units_written_pct_of_index']}% of index)"
  row
end

payload = {
  'schema' => 1,
  'variant' => Rails.application.class.module_parent_name,
  'rails_version' => Rails.version,
  'ruby_version' => RUBY_VERSION,
  'woods_gem_sha' => Open3.capture2('git', '-c', 'safe.directory=/woods-gem', '-C', '/woods-gem', 'rev-parse', '--short', 'HEAD').first.strip.presence,
  'generated' => generated,
  'index' => {
    'total_units' => total_units,
    'app_code_units' => app_units,
    'rails_source_units' => counts.fetch('rails_source', 0),
    'counts' => counts
  },
  'cold_full_extraction' => { 'wall_ms' => cold[:wall_ms], 'phases_ms' => cold[:phases],
                              'profile_total_ms' => cold[:profile_total_ms], 'profile_lines' => cold[:profile_lines] },
  'incremental' => results,
  'rss_mb' => { 'before' => rss_start, 'after' => rss_mb },
  'caveats' => [
    "p95 of #{REPS} samples is indicative, not a real tail — raise WOODS_BENCH_REPS for a meaningful one",
    'phase breakdown uses WOODS_PROFILE durations; legacy publish excludes nested sync but includes retention; unaccounted includes log rounding',
    'extraction wall time excludes process/Rails boot and mutation/reload setup; single process, single container'
  ]
}

puts
puts 'cold extraction phases (ms):'
cold[:phases].sort_by { |_, v| -v }.each { |phase, ms| puts "  #{phase.ljust(16)} #{ms}" }

puts
puts "rss after: #{payload['rss_mb']['after']} MB (delta #{(payload['rss_mb']['after'].to_f - rss_start.to_f).round(1)} MB)"

if (out = ENV['WOODS_BENCH_JSON'])
  File.write(out, "#{JSON.pretty_generate(payload)}\n")
  puts "json:      #{out}"
end

puts
puts '--- JSON ---'
puts JSON.generate(payload)
