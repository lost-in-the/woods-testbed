# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_embed_contract_smoke.rb
#
# Exercises the embed pipeline contract against every provider a host can
# actually reach, and the fail-closed refusal that protects a durable store.
#
# Why this exists: `woods_embedding_smoke.rb` proves the pipeline round-trips
# through each vector store using a locally-defined provider. It does not
# cover the *provider selection* path (`Builder#build_embedding_provider`) or
# the dimension guard, and until `:fake` became a first-class provider (#178)
# a host could not run the embed pipeline at all without a remote endpoint.
# Both are now testable with no network, so they should be.
#
# Coverage, in order:
#   1. `:fake` — always runs. No network, no store daemon. Proves provider
#      selection, chunking, and an in-memory round trip.
#   2. `:ollama` — runs when an Ollama endpoint answers. Real embeddings, and
#      the only case that proves provider-calibrated chunking differs from the
#      fake path (a tighter token budget splits units into more chunks).
#   3. Dimension guard — runs when Qdrant answers. A provider whose width
#      disagrees with an existing collection must be refused BEFORE any write,
#      and the collection must be left byte-for-byte alone.
#
# Every case skips cleanly rather than failing when its dependency is absent,
# so this runs unchanged against every variant.
#
# The rake-level exit contract (`woods:embed` exits 0 on success, non-zero on
# a refusal) is the same code path one layer up; it is asserted here by the
# error types the task converts into those exits.
#
# Endpoints are env-overridable:
#   PROBE_OLLAMA_URL  (default http://host.docker.internal:11434)
#   PROBE_QDRANT_URL  (default http://qdrant:6333)
#   PROBE_OLLAMA_MODEL (default nomic-embed-text)
#
# Known flake, not a contract violation: the :ollama case can fail with
# `Ollama API error: 400 {"error":"Post \"http://127.0.0.1:PORT/tokenize\": EOF"}`.
# That is Ollama's own model server dropping its internal tokenize connection
# mid-run; the partial run leaves points in the collection. Retry it. A real
# failure names a width, a count, or a refusal, not an Ollama transport error.
#
# Exit codes:  0 all runnable cases hold  |  1 a contract is broken

require 'json'
require 'net/http'
require 'securerandom'
require 'woods'
require 'woods/builder'
require 'woods/tasks'
require 'woods/generation'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'

OLLAMA_URL = ENV.fetch('PROBE_OLLAMA_URL', 'http://host.docker.internal:11434')
QDRANT_URL = ENV.fetch('PROBE_QDRANT_URL', 'http://qdrant:6333')
OLLAMA_MODEL = ENV.fetch('PROBE_OLLAMA_MODEL', 'nomic-embed-text')
INDEX_DIR = Pathname.new(ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods').to_s))

results = []

def assert(name)
  yield
  puts "  PASS  #{name}"
  true
rescue StandardError => e
  puts "  FAIL  #{name}"
  puts "        #{e.class}: #{e.message}"
  false
end

def skip(name, why)
  puts "  SKIP  #{name} — #{why}"
end

def reachable?(url, path = '/')
  uri = URI("#{url}#{path}")
  Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 4) do |http|
    http.request(Net::HTTP::Get.new(uri)).code.to_i < 500
  end
rescue StandardError
  false
end

# A configuration built in memory, so this script needs no initializer and
# cannot disturb the variant's own settings.
def config_for(provider:, options: {}, vector_store: :in_memory, store_options: {})
  cfg = Woods::Configuration.new
  cfg.output_dir = INDEX_DIR.to_s
  cfg.embedding_provider = provider
  cfg.embedding_options = options
  cfg.vector_store = vector_store
  cfg.vector_store_options = store_options
  cfg
end

# Build the indexer through the SAME entry point `woods:embed` uses, rather
# than re-wiring it here. Hand-wiring drifts: an earlier version of this
# script omitted the provider-tuned chunker and silently measured the wrong
# chunk counts. `Tasks.build_embed_indexer` reads the global configuration,
# so swap it for the duration and always restore.
def with_config(cfg)
  previous = Woods.configuration
  Woods.configuration = cfg
  yield
ensure
  Woods.configuration = previous
end

def indexer_for(cfg)
  with_config(cfg) do
    builder = Woods::Builder.new(cfg)
    provider = builder.build_embedding_provider
    [Woods::Tasks.build_embed_indexer, builder.build_vector_store(dimensions: provider.dimensions), provider]
  end
end

def qdrant_points(collection)
  uri = URI("#{QDRANT_URL}/collections/#{collection}")
  body = Net::HTTP.get(uri)
  JSON.parse(body).dig('result', 'points_count')
rescue StandardError
  nil
end

def delete_collection(collection)
  uri = URI("#{QDRANT_URL}/collections/#{collection}")
  Net::HTTP.start(uri.hostname, uri.port) { |h| h.request(Net::HTTP::Delete.new(uri)) }
rescue StandardError
  nil
end

puts "=== environment ==="
puts "index:  #{INDEX_DIR}"
puts "ollama: #{OLLAMA_URL} (#{reachable?(OLLAMA_URL, '/api/tags') ? 'up' : 'absent'})"
puts "qdrant: #{QDRANT_URL} (#{reachable?(QDRANT_URL, '/collections') ? 'up' : 'absent'})"
puts

unless File.exist?(File.join(Woods::Generation.new(output_dir: INDEX_DIR).payload_dir.to_s, 'manifest.json'))
  puts 'No index to embed — run woods:extract first. Nothing to check.'
  exit 0
end

# ── 1. :fake — always available ──────────────────────────────────────────
puts '=== 1. :fake provider (no network) ==='
fake_chunks = nil
results << assert(':fake is a selectable provider and embeds the index') do
  indexer, store, provider = indexer_for(config_for(provider: :fake, options: { dimensions: 256 }))
  raise "wrong width: #{provider.dimensions}" unless provider.dimensions == 256

  stats = indexer.index_all
  fake_chunks = stats[:processed]
  raise "nothing embedded: #{stats.inspect}" unless fake_chunks.to_i.positive?
  raise "errors reported: #{stats.inspect}" unless stats[:errors].to_i.zero?
  raise 'store is empty after a successful run' if store.respond_to?(:size) && store.size.to_i.zero?

  puts "        processed #{fake_chunks} chunks at 256 dims"
end

# ── 2. :ollama — real embeddings when an endpoint answers ────────────────
puts
puts '=== 2. :ollama provider (real embeddings) ==='
if reachable?(OLLAMA_URL, '/api/tags')
  collection = "woods_contract_#{SecureRandom.hex(4)}"
  ollama_chunks = nil
  results << assert(":ollama embeds the index into a live Qdrant collection") do
    unless reachable?(QDRANT_URL, '/collections')
      raise 'qdrant absent — cannot store real vectors durably'
    end

    indexer, _store, provider = indexer_for(
      config_for(provider: :ollama,
                 options: { host: OLLAMA_URL, model: OLLAMA_MODEL },
                 vector_store: :qdrant,
                 store_options: { url: QDRANT_URL, collection: collection })
    )
    stats = indexer.index_all
    ollama_chunks = stats[:processed]
    raise "errors reported: #{stats.inspect}" unless stats[:errors].to_i.zero?

    stored = qdrant_points(collection)
    raise "collection holds #{stored.inspect} points, expected #{ollama_chunks}" unless stored == ollama_chunks

    puts "        processed #{ollama_chunks} chunks at #{provider.dimensions} dims, #{stored} points stored"
  end

  results << assert('provider-calibrated chunking splits more finely than the fake path') do
    raise 'the :fake case did not run, so there is no baseline' if fake_chunks.nil?
    raise 'the :ollama case did not complete, so there is nothing to compare' if ollama_chunks.nil?
    # Ollama's BERT/WordPiece budget is far tighter than the OpenAI-style
    # estimate the fake provider inherits, so the same index must produce
    # strictly more chunks. Equal counts mean the calibration is not applied.
    unless ollama_chunks > fake_chunks
      raise "ollama #{ollama_chunks} chunks vs fake #{fake_chunks} — calibration not applied"
    end

    puts "        #{fake_chunks} chunks (fake) -> #{ollama_chunks} chunks (ollama)"
  end

  # ── 3. Dimension guard, reusing the collection just created ────────────
  puts
  puts '=== 3. dimension guard (fail closed before any write) ==='
  results << assert('a width mismatch is refused and the collection is untouched') do
    before = qdrant_points(collection)
    raise 'no populated collection to guard' unless before.to_i.positive?

    refused = begin
      indexer_for(config_for(provider: :fake, options: { dimensions: 256 },
                             vector_store: :qdrant,
                             store_options: { url: QDRANT_URL, collection: collection }))
      nil
    rescue StandardError => e
      e
    end

    raise 'the mismatch was ACCEPTED' if refused.nil?

    # Assert on the MESSAGE, not the class. Against Qdrant the refusal comes
    # from the adapter's own collection guard, which fires before the
    # pre-flight `Tasks.verify_store_dimensions!`, so the error is a
    # Woods::ConfigurationError rather than Woods::MCP::DimensionMismatch.
    # Both widths must appear, or the operator cannot tell which end is wrong.
    unless refused.message.match?(/dimension/i)
      raise "refusal does not name the dimensions: #{refused.class}: #{refused.message}"
    end
    [768, 256].each do |width|
      next if refused.message.include?(width.to_s)

      raise "refusal does not name width #{width}: #{refused.message}"
    end

    after = qdrant_points(collection)
    raise "collection changed: #{before} -> #{after}" unless before == after

    puts "        refused with #{refused.class}, points unchanged at #{after}"
  end

  delete_collection(collection)
else
  skip(':ollama provider', "nothing answering at #{OLLAMA_URL}")
  skip('dimension guard', 'depends on the ollama case having populated a collection')
end

puts
puts '=== Summary ==='
puts "passed: #{results.count(true)}    failed: #{results.count(false)}    total: #{results.size}"
exit(results.all? ? 0 : 1)
