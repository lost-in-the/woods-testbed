# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_bench.rb
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
#      app with thousands of units, where PageRank and the dependents pass
#      dominate rather than boot time.
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
#   ruby script/shared/generate_large_app.rb          # WOODS_GEN_SCALE=small|medium|large
#   bin/rails db:prepare
#   bin/rails runner script/shared/woods_bench.rb
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

APP        = Rails.root
INDEX_DIR  = Pathname.new(ENV.fetch('WOODS_OUTPUT', APP.join('tmp/woods').to_s))
REPS       = Integer(ENV.fetch('WOODS_BENCH_REPS', '7'))
CHANGE_DIR = APP.join('script/shared/bench_changes')

require 'woods'
require 'woods/extractor'

# ── Phase breakdown, without a gem change ─────────────────────────────────
#
# Extractor emits no ActiveSupport::Notifications events (there is no
# instrumentation on the extraction path at all), so the phases cannot be
# subscribed to. It *does* log a marker at the top of each one, so a logger that
# stamps every line with a monotonic clock reading gives a real breakdown
# derived from the run rather than guessed at.
#
# This is why "PageRank dominates" can stop being a hypothesis.
class PhaseLogger < Logger
  PHASES = {
    /Deduplicating results/ => 'extract',
    /Resolving dependents/ => 'dedupe',
    /Analyzing dependency graph/ => 'dependents',
    /Enriching with git data/ => 'graph_analysis',
    /Normalizing file paths/ => 'git_enrich',
    /Writing output/ => 'normalize'
  }.freeze

  attr_reader :marks

  def initialize
    super($stdout)
    self.level = Logger::INFO
    @marks = []
  end

  def add(severity, message = nil, progname = nil)
    text = message || progname
    @marks << [now, text.to_s] if text.is_a?(String) && text.include?('[Woods]')
    true
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Turn the marker stream into named durations. Each PHASES entry names the
  # phase that *ended* when that marker was logged, which is what makes the
  # arithmetic honest: the marker announces the next phase starting.
  def phase_durations(started_at, finished_at)
    out = {}
    previous = started_at

    @marks.each do |(at, text)|
      label = PHASES.find { |pattern, _| pattern.match?(text) }&.last
      next unless label

      out[label] = ((at - previous) * 1000).round(1)
      previous = at
    end

    # Everything after the "Writing output" marker: the per-unit JSON writes,
    # the graph, the analysis, the manifest, the snapshot and the generation
    # bump. Named for what it is — on a large tree this is dominated by
    # AtomicFile's fsync per unit file, not by anything analytical.
    out['write_and_publish'] = ((finished_at - previous) * 1000).round(1)
    out
  end
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
# woods:clean first, deliberately. A full extraction overwrites unit files but
# does not prune orphans, so extracting into a directory that has seen a
# different tree over-reports every count (lost-in-the/woods#177) — which would
# silently inflate the very numbers this script exists to produce.
def cold_full_extraction
  FileUtils.rm_rf(INDEX_DIR)

  logger = PhaseLogger.new
  original = Rails.logger
  Rails.logger = logger

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Woods::Extractor.new(output_dir: INDEX_DIR).extract_all
  finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  { wall_ms: ((finished - started) * 1000).round(1), phases: logger.phase_durations(started, finished) }
ensure
  Rails.logger = original if original
end

# One incremental cycle over a real edit, applied and reverted so the tree ends
# where it started and every repetition measures the same change.
def incremental_cycle(spec)
  path = APP.join(spec[:path])
  original = path.read
  mutated = spec[:apply].call(original)

  raise "change script #{spec[:file]} did not modify #{spec[:path]} — its anchor has drifted" if mutated == original

  path.write(mutated)

  before = read_json(INDEX_DIR.join('manifest.json'))&.fetch('total_units', nil)

  extractor = Woods::Extractor.new(output_dir: INDEX_DIR)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  results = extractor.extract_changed([path.to_s])
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)

  # extract_changed returns `touched.to_a` — a flat Array of unit identifiers,
  # NOT a Hash keyed by type the way extract_all's result is. Treating it as a
  # Hash silently reports 0 units written for every scenario, which is precisely
  # the number finding 16 needs.
  touched = Array(results).size
  after = read_json(INDEX_DIR.join('manifest.json'))&.fetch('total_units', nil)

  { ms: elapsed, units_written: touched, index_before: before, index_after: after, rss_mb: rss_mb }
ensure
  path.write(original) if original
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

manifest = read_json(INDEX_DIR.join('manifest.json')) || {}
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
    'rss_mb_after' => samples.last[:rss_mb]
  }
  puts "p50 #{row['p50_ms']} ms  p95 #{row['p95_ms']} ms  wrote #{written} units (#{row['units_written_pct_of_index']}% of index)"
  row
end

payload = {
  'schema' => 1,
  'variant' => Rails.application.class.module_parent_name,
  'rails_version' => Rails.version,
  'ruby_version' => RUBY_VERSION,
  'woods_gem_sha' => `git -C /woods-gem rev-parse --short HEAD 2>/dev/null`.strip.presence,
  'generated' => generated,
  'index' => {
    'total_units' => total_units,
    'app_code_units' => app_units,
    'rails_source_units' => counts.fetch('rails_source', 0),
    'counts' => counts
  },
  'cold_full_extraction' => { 'wall_ms' => cold[:wall_ms], 'phases_ms' => cold[:phases] },
  'incremental' => results,
  'rss_mb' => { 'before' => rss_start, 'after' => rss_mb },
  'caveats' => [
    "p95 of #{REPS} samples is indicative, not a real tail — raise WOODS_BENCH_REPS for a meaningful one",
    'phase breakdown is derived from Extractor log markers, not instrumentation; the extraction path emits no ActiveSupport::Notifications events',
    'single process, single container — not a multi-daemon or bind-mount-latency measurement'
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
