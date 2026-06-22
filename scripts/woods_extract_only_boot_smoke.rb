# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_extract_only_boot_smoke.rb
#
# Smoke-tests the extract-only Index Server boot behaviour (#138) against a real
# Rails boot. Version-agnostic: prints the detected Rails version.
#
# Since 1.3.0 the Index Server raised MissingArtifact at boot unless woods.json
# existed or WOODS_ALLOW_AUTODETECT=1 was set. Extract-only hosts (woods:extract,
# no embedding provider) now boot in pattern/structural mode by default; strict
# deployments opt into fail-closed with WOODS_REQUIRE_INDEX=1.

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
puts '=== Summary ==='
passed = results.count(true)
failed = results.count(false)
puts "passed: #{passed}    failed: #{failed}    total: #{results.size}"
exit(failed.zero? ? 0 : 1)
