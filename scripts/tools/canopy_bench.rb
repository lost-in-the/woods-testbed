# frozen_string_literal: true
# Nonmutating report/query benchmark; pair with woods_bench.rb for source scale.
require 'json'
require 'benchmark'
require 'open3'
require 'woods/mcp/index_reader'
manifest = JSON.parse(Testbed::Dataset.manifest_path.read)
reader = Woods::MCP::IndexReader.new(ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods').to_s))
reps = Integer(ENV.fetch('CANOPY_BENCH_REPS', '7'))
raise 'Use at least one repetition' unless reps.positive?
organization = Organization.find_by!(slug: 'canopy')
at = Time.zone.parse(manifest.fetch('reference_time'))
answer = nil
times = Array.new(reps) do
  Benchmark.realtime do
    ActiveRecord::Base.uncached do
      report = EditorialReport.new(organization, at: at)
      answer = { review_backlog: report.review_backlog.count, overdue_cents: report.overdue_cents, newsletter: report.newsletter_outcomes }
    end
  end * 1000
end.sort
sha, status = Open3.capture2('git', '-c', 'safe.directory=' + Gem.loaded_specs.fetch('woods').full_gem_path, '-C', Gem.loaded_specs.fetch('woods').full_gem_path, 'rev-parse', 'HEAD')
result = {
  fixture_version: manifest['version'], profile: manifest['profile'], counts: manifest['counts'],
  seed_seconds: manifest['seed_seconds'], reference_time: manifest['reference_time'],
  woods_sha: status.success? ? sha.strip : 'unknown', ruby: RUBY_VERSION, rails: Rails.version,
  source_units: reader.manifest['total_units'], framework_units: reader.manifest.fetch('counts').fetch('rails_source', 0),
  query_ms: { repetitions: reps, median: times[reps / 2].round(2), max: times.last.round(2) },
  answers: answer, rss_kib: File.read('/proc/self/status')[/^VmRSS:\s+(\d+)/, 1].to_i
}
output = Rails.root.join(ENV.fetch('CANOPY_BENCH_JSON', "tmp/canopy_bench_#{manifest['profile']}.json"))
output.write(JSON.pretty_generate(result) + "\n")
puts JSON.pretty_generate(result)
