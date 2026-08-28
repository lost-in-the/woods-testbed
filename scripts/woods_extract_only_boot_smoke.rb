# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_extract_only_boot_smoke.rb
#
# Smoke-tests the extract-only Index Server boot behaviour (#138) against a real
# Rails boot. Version-agnostic: prints the detected Rails version.
#
# Extract-only hosts (woods:extract, no embedding provider) boot the Index
# Server in pattern/structural mode by default; strict deployments opt into
# fail-closed with WOODS_REQUIRE_INDEX=1.
#
# This script also stages the cross-UID permission proof for woods#252: it
# writes watch_status.json (the one artifact widened to 0644) into the real,
# bind-mounted index dir, samples payload artifacts, and records everything in
# permission_proof.json. The host-side half of the proof lives in
# scripts/tools/woods_permission_proof_check.rb, which CI runs against this
# file before the ownership-changing step gets a chance to erase the UID
# boundary. Mirrors spec/watch/status_spec.rb in the gem, which can only pin
# the mode in-process; the cross-boundary consumer needs this split proof.

require 'json'
require 'tmpdir'
require 'woods'
require 'woods/index_artifact'
require 'woods/mcp/errors'
require 'woods/mcp/config_resolver'

results = []

def assert(name)
  yield
  puts "  PASS  #{name}"
  true
rescue StandardError => e
  puts "  FAIL  #{name}: #{e.class}: #{e.message}"
  false
end

def skip(name, reason)
  puts "  SKIP  #{name}: #{reason}"
end

def blank_config
  cfg = Woods::Configuration.new
  cfg.embedding_provider = nil
  cfg
end

puts '=== Rails environment ==='
puts "Rails:           #{Rails.version}"
puts "Ruby:            #{RUBY_VERSION}"
puts

Dir.mktmpdir('woods_extract_only') do |dir|
  artifact = Woods::IndexArtifact.new(dir)

  puts '=== extract-only default: boots in pattern mode, no MissingArtifact (#138) ==='

  results << assert('resolve without woods.json/provider returns :autodetect, nil provider') do
    config, source = Woods::MCP::ConfigResolver.resolve(
      blank_config, artifact: artifact, env: {}, ollama_probe: -> { false }
    )
    raise "expected :autodetect, got #{source.inspect}" unless source == :autodetect
    raise 'expected nil embedding_provider (pattern mode)' unless config.embedding_provider.nil?
  end

  results << assert('does NOT raise MissingArtifact by default') do
    Woods::MCP::ConfigResolver.resolve(
      blank_config, artifact: artifact, env: {}, ollama_probe: -> { false }
    )
  end

  puts
  puts '=== strict opt-in: WOODS_REQUIRE_INDEX=1 fails closed ==='

  results << assert('raises MissingArtifact under WOODS_REQUIRE_INDEX=1') do
    Woods::MCP::ConfigResolver.resolve(
      blank_config, artifact: artifact,
                    env: { 'WOODS_REQUIRE_INDEX' => '1' }, ollama_probe: -> { false }
    )
    raise 'expected MissingArtifact'
  rescue Woods::MCP::MissingArtifact
    # expected
  end

  puts
  puts '=== legacy WOODS_ALLOW_AUTODETECT=1 still tolerated (back-compat no-op) ==='

  results << assert('still resolves :autodetect with the legacy flag set') do
    _config, source = Woods::MCP::ConfigResolver.resolve(
      blank_config, artifact: artifact,
                    env: { 'WOODS_ALLOW_AUTODETECT' => '1' }, ollama_probe: -> { false }
    )
    raise "expected :autodetect, got #{source.inspect}" unless source == :autodetect
  end
end

puts
puts '=== permission contract: 0644 status read cross-UID, 0600 payloads (woods#252) ==='

# The real index dir, not the throwaway tmpdir above: the whole point is a
# file the container writes and a DIFFERENT host UID later reads through the
# apps/<variant> bind mount. This is where woods:extract just published, so
# the payload samples are the real artifacts, not fixtures.
index_dir = File.expand_path(Woods.configuration.output_dir.to_s, Rails.root.to_s)

# The mode: kwarg on AtomicFile.write IS the woods#252 contract. On a gem that
# predates it, watch_status.json is born 0600 and no host UID but the writer
# can read it, so the cross-UID assertions must wait for the widening instead
# of asserting its absence. Nothing autoloads the gem's namespaces here, so
# the require comes before the probe (both main and #252 ship watch/status).
status_capable = begin
  require 'woods/watch/status'
  Woods::AtomicFile.method(:write).parameters.any? do |kind, name|
    name == :mode && %i[key opt].include?(kind)
  end
rescue LoadError, NameError
  false
end
status_contract = status_capable ? '0644' : 'predates_252'

puts "index dir:       #{index_dir}"
puts "status contract: #{status_contract}"
puts "container uid:   #{Process.uid}"

proof = {
  'container_uid' => Process.uid,
  'index_dir' => index_dir,
  'status_contract' => status_contract,
  'watch_status' => nil,
  'extracted' => false,
  'payload_samples' => []
}

if status_capable
  results << assert('watch_status.json written by the gem into the mounted index dir') do
    Woods::Watch::Status.new(output_dir: index_dir).write(state: :running)
    raise 'gem did not leave watch_status.json behind' unless File.exist?(File.join(index_dir, Woods::Watch::Status::FILENAME))
  end

  status_path = File.join(index_dir, Woods::Watch::Status::FILENAME)
  stat = File.stat(status_path)

  results << assert('watch_status.json is 0644: owner-only write, world-readable') do
    raise "expected 0644, got #{format '%o', stat.mode & 0o777}" unless stat.mode & 0o777 == 0o644
  end

  results << assert('watch_status.json is owned by the container UID') do
    raise "owner uid #{stat.uid}, container uid #{Process.uid}" unless stat.uid == Process.uid
  end

  proof['watch_status'] = {
    'path' => Woods::Watch::Status::FILENAME,
    'mode' => format('%o', stat.mode & 0o777),
    'uid' => stat.uid
  }
else
  skip('watch_status.json cross-UID proof', 'gem predates AtomicFile mode: (woods#252 not merged)')
end

# Sample the current generation's payload artifacts. 2.0 publishes into
# payloads/<generation>/ and generation.json names it; pre-payload indexes
# keep the artifacts flat in the output dir (same fallback the CI coverage
# step uses).
generation_path = File.join(index_dir, 'generation.json')
if File.exist?(generation_path)
  payload_name = JSON.parse(File.read(generation_path, encoding: 'UTF-8'))['payload']
  sample_base = payload_name ? File.join(index_dir, payload_name) : index_dir
  names = (%w[manifest.json] + Dir.children(sample_base).sort)
          .select { |n| n.end_with?('.json') }
          .uniq
          .first(5)

  results << assert("payload artifacts are not group- or world-readable (#{names.size} sampled)") do
    raise 'no payload artifacts found to sample' if names.empty?

    names.each do |name|
      mode = File.stat(File.join(sample_base, name)).mode & 0o777
      raise "#{name} is #{format '%o', mode}, expected owner-only 0600" unless mode == 0o600
    end
  end

  proof['extracted'] = true
  proof['payload_samples'] = names.map do |name|
    stat = File.stat(File.join(sample_base, name))
    { 'path' => File.join(payload_name.to_s, name), 'mode' => format('%o', stat.mode & 0o777), 'uid' => stat.uid }
  end
else
  skip('payload 0600 sampling', 'no generation.json: run woods:extract first (CI always does)')
end

# The host checker's ticket. Deliberately NOT AtomicFile: that would born it
# 0600 and lock the host UID out of the very file that tells it what to prove.
# Plain File.write under the default umask gives the 0644 a read-through
# ticket needs.
File.write(File.join(index_dir, 'permission_proof.json'), JSON.pretty_generate(proof) << "\n")

puts
puts '=== Summary ==='
passed = results.count(true)
failed = results.count(false)
puts "passed: #{passed}    failed: #{failed}    total: #{results.size}"
exit(failed.zero? ? 0 : 1)
