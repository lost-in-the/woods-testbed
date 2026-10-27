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
#   Run db:prepare once, on a fresh database, before the bench and not between
#   runs: it rewrites db/schema.rb, and on a copied database that already
#   holds an earlier generation's gen_* tables it collides with the generated
#   migrations and leaves a rewritten dump behind. The gem lists db/schema.rb
#   among the paths whose change invalidates boot-captured state (the schema
#   cache and column information a Rails process captures once), so
#   `extract_changed` refuses such a path outright and only a full extraction
#   in a fresh Rails process is an honest measurement. The bench decides that
#   up front from the gem's own rule (Woods::InputRules) and measures such a
#   scenario (schema) as a full extraction in a freshly booted `bin/rails
#   runner` child (woods_bench_full_extraction.rb), timed inside the child so
#   boot stays excluded. That sample is a repeat full extraction over the
#   payload the cold row left behind, not a second cold run, and its RSS is
#   the child's. The row and the JSON say so (`mode: full`). Restoring the
#   edit needs a fresh process too, so each repetition boots twice.
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
begin
  require 'woods/input_rules'
rescue LoadError
  # Older gem without the shared fresh-process rule: fall back to its reload policy.
  require 'woods/reload_policy'
end

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

  touched, mode, measurement = reextract(Woods::Extractor.new(output_dir: INDEX_DIR), spec[:path])
  after = current_manifest&.fetch('total_units', nil)

  # A fresh-process sample carries the child's own RSS (nil if the child could
  # not read it); this process never ran that extraction, so its RSS is not a
  # substitute. Incremental samples carry this process's RSS.
  { ms: measurement[:wall_ms], phases_ms: measurement[:phases],
    profile_total_ms: measurement[:profile_total_ms], profile_lines: measurement[:profile_lines],
    units_written: touched, index_before: before, index_after: after,
    rss_mb: measurement.key?(:rss_mb) ? measurement[:rss_mb] : rss_mb, mode: mode }
ensure
  if original
    path.write(original)
    Rails.application.reloader.reload!
    reextract(Woods::Extractor.new(output_dir: INDEX_DIR), spec[:path])
  end
end

# The gem refuses `extract_changed` over a path whose change invalidates
# boot-captured state (db/schema.rb: the schema cache and column information
# this process captured at boot), because only a fresh process can rebuild
# that state. Decide that up front from the gem's own rule, never from the
# wording of its refusal.
#
# @param relative_path [String] Rails.root-relative path the scenario edits
# @return [Boolean]
def restart_sensitive?(relative_path)
  if defined?(Woods::InputRules)
    Woods::InputRules.new.action(relative_path) == :full
  else
    Woods::ReloadPolicy.new.classify(relative_path) == :restart
  end
end

FULL_EXTRACTION_CHILD  = Pathname.new(__dir__).join('woods_bench_full_extraction.rb')
FULL_EXTRACTION_MARKER = 'WOODS_BENCH_FULL_EXTRACTION '

# A full extraction in a freshly booted Rails process, whose boot captures
# the schema state the edit invalidated. Wall time, phases and RSS are the
# child's own, measured around `extract_all` inside it; the spawn and the
# boot are excluded, as Rails boot is for every other sample. The bootsnap
# cache is left alone: these apps boot with eager_load off, so app files are
# first loaded inside the child's timed `eager load` phase, and an emptied
# cache would charge every compile to the measurement. The edited dump is
# not loaded as code, and bootsnap keys its entries by mtime and size anyway.
#
# @return [Array(Integer, Hash)] units written and the child's measurement
# @raise [RuntimeError] when the child exits non-zero or reports nothing
def fresh_process_full_extraction
  env = { 'WOODS_OUTPUT' => INDEX_DIR.to_s, 'WOODS_PROFILE' => '1' }
  stdout, stderr, status = Open3.capture3(env, APP.join('bin/rails').to_s, 'runner',
                                          FULL_EXTRACTION_CHILD.to_s, chdir: APP.to_s)
  line = stdout.lines.reverse.find { |candidate| candidate.start_with?(FULL_EXTRACTION_MARKER) }
  unless status.success? && line
    raise "fresh-process full extraction failed (exit #{status.exitstatus.inspect}, no report line); " \
          "stderr tail:\n#{stderr.lines.last(20).join}stdout tail:\n#{stdout.lines.last(5).join}"
  end

  report = JSON.parse(line.delete_prefix(FULL_EXTRACTION_MARKER))
  [report.fetch('units_written'),
   { wall_ms: report.fetch('wall_ms'), phases: report.fetch('phases_ms'),
     profile_total_ms: report['profile_total_ms'], profile_lines: report.fetch('profile_lines'),
     rss_mb: report['rss_mb'] }]
end

# Re-extract after the scenario's edit: incrementally in this process, or as
# a full extraction in a fresh one when the edited path is boot-captured.
#
# @param extractor [Woods::Extractor]
# @param relative_path [String] Rails.root-relative path the scenario edits
# @return [Array(Integer, String, Hash)] units written, the mode run, the measurement
def reextract(extractor, relative_path)
  if restart_sensitive?(relative_path)
    units, measurement = fresh_process_full_extraction
    [units, 'full', measurement]
  else
    results, measurement = profile_extraction { extractor.extract_changed([APP.join(relative_path).to_s]) }
    # extract_changed returns `touched.to_a`, a flat Array of unit identifiers
    # (extract_all's per-type Hash is counted in the child instead). Treating
    # the Array as a Hash silently reported 0 units written for every scenario.
    [Array(results).size, 'incremental', measurement]
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
    'mode' => samples.map { |s| s[:mode] }.uniq.join('+'),
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
  puts "p50 #{row['p50_ms']} ms  p95 #{row['p95_ms']} ms  wrote #{written} units (#{row['units_written_pct_of_index']}% of index)#{row['mode'] == 'incremental' ? '' : "  mode=#{row['mode']}"}"
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
    'extraction wall time excludes process/Rails boot and mutation/reload setup; single container',
    'a scenario the gem refuses incrementally (db/schema.rb invalidates boot-captured schema state) is measured ' \
    'as a repeat full extraction over the existing payload in a freshly booted bin/rails runner child, timed ' \
    'inside the child, and carries mode=full with the child\'s rss_mb; restoring the edit boots a second child ' \
    'per repetition'
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
