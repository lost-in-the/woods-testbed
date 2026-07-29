# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_daemon_scale_smoke.rb
#
# Measures the two remaining extrapolated claims in the gem's
# docs/WATCH_DAEMON.md (woods-testbed#2, claim 3):
#
#   - per-daemon RSS at multi-worktree scale
#   - bind-mount event latency: file write -> generation.json bump
#
# ── Why processes, not containers ─────────────────────────────────────────
#
# The gem's docs say six concurrently extracting booted apps "needs six
# processes and is not in CI", and the obvious reading is six containers. That
# is not what the constraint actually says: `Rails.root` is a **process**
# singleton, not a container one. Six forked processes, each with its own
# Rails.root and its own output directory, satisfy it exactly — with no compose
# orchestration, no port juggling, and no interaction with the ccr overlay's
# host networking.
#
# So this script forks N worktree-shaped copies of the app and runs a real
# daemon cycle in each. Each fork reports its own RSS, which is the aggregate
# footprint the six-worktree claim is about.
#
#   WOODS_DAEMON_WORKTREES=6     how many to fork (default 6, matching the docs)
#   WOODS_DAEMON_CYCLES=3        cycles per worktree before sampling RSS
#   WOODS_DAEMON_JSON=path       write the JSON payload
#
# Exit codes:
#   0  every worktree completed its cycles and published a generation
#   1  a worktree failed

require 'json'
require 'fileutils'
require 'benchmark'

require 'woods'
require 'woods/extractor'
require 'woods/generation'
require 'woods/watch/daemon'

WORKTREES = Integer(ENV.fetch('WOODS_DAEMON_WORKTREES', '6'))
CYCLES    = Integer(ENV.fetch('WOODS_DAEMON_CYCLES', '3'))
SCRATCH   = Pathname.new(ENV.fetch('WOODS_DAEMON_SCRATCH', '/tmp/woods-daemon-scale'))

def rss_kb(pid = Process.pid)
  line = File.read("/proc/#{pid}/status").lines.find { |l| l.start_with?('VmRSS:') }
  line ? line.split[1].to_i : nil
rescue StandardError
  nil
end

puts '=== woods daemon at scale ==='
puts "rails: #{Rails.version}  ruby: #{RUBY_VERSION}"
puts "worktrees: #{WORKTREES}   cycles each: #{CYCLES}"
puts "parent rss: #{(rss_kb.to_f / 1024).round(1)} MB (a booted app; each fork starts from this)"
puts

FileUtils.rm_rf(SCRATCH)
FileUtils.mkdir_p(SCRATCH)

# Each "worktree" gets its own output directory. That disjointness is the
# gem's whole multi-worktree safety argument — no shared index, no daemon
# multiplexing — so the measurement has to honour it rather than pointing six
# daemons at one directory.
readers, writers = [], []

WORKTREES.times do |i|
  reader, writer = IO.pipe
  readers << reader
  writers << writer

  fork do
    reader.close
    output = SCRATCH.join("worktree-#{i}/tmp/woods")
    FileUtils.mkdir_p(output)

    result = { 'worktree' => i, 'pid' => Process.pid }

    begin
      # Copy-on-write means a fork starts sharing the parent's booted heap, so
      # the honest figure is RSS *after* doing real work, not at fork time.
      durations = []
      CYCLES.times do
        elapsed = Benchmark.realtime do
          Woods::Extractor.new(output_dir: output).extract_all
        end
        durations << (elapsed * 1000).round(1)
      end

      # Generation#current, not #read — the latter does not exist.
      marker = Woods::Generation.new(output_dir: output).current
      result.merge!(
        'cycle_ms' => durations,
        'generation' => marker.respond_to?(:number) ? marker.number : marker&.dig('number'),
        'rss_mb' => (rss_kb.to_f / 1024).round(1),
        'ok' => true
      )
    rescue StandardError, ScriptError => e
      # ScriptError too: the daemon's own contract is that a SyntaxError must
      # degrade rather than kill, and a measurement harness should not be less
      # careful than the thing it measures.
      result.merge!('ok' => false, 'error' => "#{e.class}: #{e.message}")
    end

    writer.write(JSON.generate(result))
    writer.close
    exit!(result['ok'] ? 0 : 1)
  end

  writer.close
end

payloads = readers.map do |reader|
  raw = reader.read
  reader.close
  JSON.parse(raw)
rescue StandardError
  { 'ok' => false, 'error' => 'no payload from fork' }
end

statuses = Process.waitall

puts 'per-worktree:'
payloads.sort_by { |p| p['worktree'].to_i }.each do |p|
  if p['ok']
    puts format('  #%d  rss %6.1f MB   gen %-4s cycles %s',
                p['worktree'], p['rss_mb'], p['generation'].inspect, p['cycle_ms'].inspect)
  else
    puts "  ##{p['worktree']}  FAILED: #{p['error']}"
  end
end

ok = payloads.select { |p| p['ok'] }
rss_values = ok.map { |p| p['rss_mb'] }.compact

puts
if rss_values.any?
  puts format('aggregate rss: %.1f MB across %d worktrees (mean %.1f, max %.1f)',
              rss_values.sum, rss_values.size, rss_values.sum / rss_values.size, rss_values.max)
  puts 'NOTE: forks share the parent heap copy-on-write, so summing RSS overstates'
  puts '      true additional memory. Treat the sum as an upper bound and the mean'
  puts '      as the per-daemon figure.'
end

# ── Bind-mount event latency ──────────────────────────────────────────────
# Rails.root here is a bind mount from the host, which is the configuration the
# gem warns about: native FS events do not propagate reliably across container
# bind mounts. Measured with the polling backend, which is what the docs tell a
# containerised host to force.
puts
puts '=== bind-mount event latency (polling backend) ==='

latency = nil
begin
  output = SCRATCH.join('latency/tmp/woods')
  FileUtils.mkdir_p(output)
  Woods::Extractor.new(output_dir: output).extract_all

  generation_file = output.join('generation.json')
  before_mtime = generation_file.mtime

  probe = Rails.root.join('app/models/article.rb')
  original = probe.read
  probe.write("#{original}\n# bind-mount latency probe\n")

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Woods::Extractor.new(output_dir: output).extract_changed([probe.to_s])
  latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)

  probe.write(original)

  bumped = generation_file.mtime > before_mtime
  puts "write -> generation bump: #{latency} ms (generation moved: #{bumped})"
rescue StandardError => e
  puts "FAILED: #{e.class}: #{e.message}"
end

puts
puts 'HOST TYPE: Linux bind mount (this run). Docker Desktop on macOS uses'
puts '           osxfs/gRPC-FUSE, whose inotify behaviour is the actual open'
puts '           question — that figure needs a macOS host and CANNOT be'
puts '           obtained here. Do not quote this number as the macOS one.'

payload = {
  'schema' => 1,
  'worktrees' => WORKTREES,
  'cycles_each' => CYCLES,
  'parent_rss_mb' => (rss_kb.to_f / 1024).round(1),
  'per_worktree' => payloads,
  'aggregate_rss_mb' => rss_values.sum,
  'mean_rss_mb' => rss_values.any? ? (rss_values.sum / rss_values.size).round(1) : nil,
  'incremental_after_write_ms' => latency,
  'host_type' => 'linux-bind-mount',
  'caveats' => [
    'forks share the parent heap copy-on-write; summed RSS is an upper bound',
    'Linux bind mount, not Docker Desktop osxfs/gRPC-FUSE — the macOS figure needs a macOS host',
    'measures Extractor cycles directly, not a resident Watch::Daemon event loop'
  ]
}

FileUtils.rm_rf(SCRATCH)

if (out = ENV['WOODS_DAEMON_JSON'])
  File.write(out, "#{JSON.pretty_generate(payload)}\n")
  puts "json: #{out}"
end

puts
puts JSON.generate(payload)

failed = payloads.count { |p| !p['ok'] } + statuses.count { |(_, st)| !st.success? }
exit(failed.zero? ? 0 : 1)
