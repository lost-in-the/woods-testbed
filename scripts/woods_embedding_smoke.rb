# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_embedding_smoke.rb
#
# Round-trips the embedding pipeline through every configured vector store —
# in-memory always, pgvector and Qdrant when the `backends` compose profile is
# up. The testbed previously ran SQLite only, so nothing exercised the gem's
# backend-agnostic claim end to end (woods-testbed#2 §1.3).
#
# ── Why the provider is defined here rather than imported ─────────────────
#
# `Woods::Embedding::Provider::Fake` already exists and is exactly what this
# needs — bag-of-words hashing, L2-normalised, so cosine similarity stays
# meaningful — but it lives in the gem's `spec/support/`, which is not on the
# load path of a host app. And `Builder#build_embedding_provider` only knows
# `:openai` and `:ollama`, so `rake woods:embed` cannot run at all without a live
# remote endpoint.
#
# `Embedding::Indexer` does take `provider:` as a kwarg, so a script can build
# the pipeline directly with any object satisfying the interface. That is the
# zero-gem-change path, and it is what this uses. Promoting Provider::Fake into
# lib/ (or letting Builder accept an injected provider) would let this test the
# actual rake-level chain instead — filed as lost-in-the/woods#178.
#
# Deterministic on purpose: no network, no model download, same vectors every
# run, so this is safe in CI. The real-provider path (Ollama) is a separate,
# opt-in tier and deliberately not here.
#
# Bring the backends up first:
#   docker compose --profile backends up -d postgres qdrant
#
# Exit codes:
#   0  every available store round-tripped
#   1  a store was reachable but the round-trip failed

require 'json'
require 'digest'

require 'woods'
require 'woods/embedding/indexer'
require 'woods/embedding/provider'
require 'woods/embedding/text_preparer'
require 'woods/storage/vector_store'

INDEX_DIR = Pathname.new(ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods').to_s))

# Woods 2.0 publishes each generation under payloads/gen-N/ and names the
# current one in generation.json; older gems wrote a flat index. Resolve the
# same way the gem does so this script reads whichever layout is on disk.
PAYLOAD_DIR = begin
  require 'woods/generation'
  Woods::Generation.new(output_dir: INDEX_DIR).payload_dir
rescue LoadError, NameError
  INDEX_DIR
end

results = []

def assert(name)
  yield
  puts "  PASS  #{name}"
  true
rescue StandardError => e
  puts "  FAIL  #{name}: #{e.class}: #{e.message}"
  false
end

# Deterministic bag-of-words provider. Words hash to buckets and the vector is
# L2-normalised, so two texts sharing vocabulary really do score higher on cosine
# similarity — which is what makes a retrieval assertion meaningful rather than
# just checking that bytes went in and came out.
class DeterministicProvider
  DIMS = 128

  def embed(text)
    vec = Array.new(DIMS, 0.0)
    text.to_s.downcase.scan(/[a-z_][a-z0-9_]*/).each do |word|
      vec[Digest::SHA256.hexdigest(word).to_i(16) % DIMS] += 1.0
    end
    magnitude = Math.sqrt(vec.sum { |v| v**2 })
    magnitude.zero? ? vec : vec.map { |v| v / magnitude }
  end

  def embed_batch(texts) = texts.map { |t| embed(t) }
  def dimensions = DIMS
  def model_name = 'deterministic-testbed'
  def max_input_tokens = nil
end

PROVIDER = DeterministicProvider.new

puts '=== Rails environment ==='
puts "Rails:      #{Rails.version}   Ruby: #{RUBY_VERSION}"
puts "AR adapter: #{ActiveRecord::Base.connection_pool.with_connection(&:adapter_name)}"
puts "Index:      #{INDEX_DIR}"
puts

unless PAYLOAD_DIR.join('manifest.json').file?
  warn "No index at #{INDEX_DIR}. Run `bin/rails woods:extract` first."
  exit 1
end

# ── Which stores can we reach? ────────────────────────────────────────────
# Probed rather than assumed, so the script is useful whether or not the
# backends profile is up. A store that is simply absent is skipped and said so;
# a store that is present but broken fails.
def reachable?(host, port)
  require 'socket'
  Socket.tcp(host, port, connect_timeout: 2, &:close)
  true
rescue StandardError
  false
end

PG_HOST = ENV.fetch('WOODS_PG_HOST', 'postgres')
PG_PORT = Integer(ENV.fetch('WOODS_PG_PORT', '5432'))
QDRANT_HOST = ENV.fetch('WOODS_QDRANT_HOST', 'qdrant')
QDRANT_PORT = Integer(ENV.fetch('WOODS_QDRANT_PORT', '6333'))

stores = { 'in_memory' => -> { Woods::Storage::VectorStore::InMemory.new } }

if reachable?(PG_HOST, PG_PORT)
  stores['pgvector'] = lambda do
    require 'woods/storage/pgvector'

    # The adapter calls #execute and #quote on whatever it is given, so it needs
    # an ActiveRecord connection — a connection *string* fails with
    # "undefined method `quote' for an instance of String". A secondary abstract
    # class keeps this off the app's own (SQLite) connection.
    unless defined?(VectorDb)
      Object.const_set(:VectorDb, Class.new(ActiveRecord::Base) { self.abstract_class = true })
      VectorDb.establish_connection(
        adapter: 'postgresql', host: PG_HOST, port: PG_PORT,
        username: 'postgres', password: 'woods', database: 'woods_testbed'
      )
    end

    store = Woods::Storage::VectorStore::Pgvector.new(
      connection: VectorDb.connection, dimensions: PROVIDER.dimensions
    )
    store.ensure_schema!
    store
  end
else
  puts "SKIP  pgvector — nothing listening on #{PG_HOST}:#{PG_PORT} " \
       '(docker compose --profile backends up -d postgres)'
end

if reachable?(QDRANT_HOST, QDRANT_PORT)
  stores['qdrant'] = lambda do
    require 'woods/storage/qdrant'
    store = Woods::Storage::VectorStore::Qdrant.new(
      url: "http://#{QDRANT_HOST}:#{QDRANT_PORT}",
      collection: 'woods_testbed_smoke',
      dimensions: PROVIDER.dimensions
    )
    # Qdrant collections are not created implicitly on first upsert — the
    # counterpart to pgvector's ensure_schema!. Omitting it 404s every call.
    #
    # But unlike Pgvector#ensure_schema! (documented "safe to call multiple
    # times (uses IF NOT EXISTS)"), this one raises 409 when the collection
    # already exists — so an `ensure_`-named method is not idempotent. Tolerated
    # here so a second run of this script works; reported upstream.
    begin
      store.ensure_collection!(dimensions: PROVIDER.dimensions)
    rescue Woods::Error => e
      raise unless e.message.include?('already exists')
    end
    store
  end
else
  puts "SKIP  qdrant — nothing listening on #{QDRANT_HOST}:#{QDRANT_PORT} " \
       '(docker compose --profile backends up -d qdrant)'
end

puts

stores.each do |name, build|
  puts "=== #{name} ==="

  store = nil
  results << assert("#{name}: store constructs") { store = build.call }
  next if store.nil?

  indexer = nil
  results << assert("#{name}: indexer builds with an injected provider") do
    indexer = Woods::Embedding::Indexer.new(
      provider: PROVIDER,
      text_preparer: Woods::Embedding::TextPreparer.new,
      vector_store: store,
      output_dir: INDEX_DIR
    )
  end
  next if indexer.nil?

  stats = nil
  results << assert("#{name}: index_all embeds the extracted units") do
    stats = indexer.index_all
    raise "no units embedded (stats: #{stats.inspect})" if stats.nil?
  end

  results << assert("#{name}: a query returns hits") do
    hits = store.search(PROVIDER.embed('article published author'), limit: 5)
    raise 'search returned nothing' if hits.nil? || hits.empty?
  end

  # Relevance, not dimensionality: search results are a Struct that carries an
  # id and a score but no vector, so there is nothing to measure dimensions on.
  # What IS worth asserting is that the ranking means something — a query sharing
  # vocabulary with a unit should rank it above an unrelated one, which is the
  # property the L2-normalised provider exists to make testable.
  results << assert("#{name}: ranking responds to vocabulary overlap") do
    related = store.search(PROVIDER.embed('article published author slug'), limit: 3)
    raise 'no results for a domain query' if related.empty?

    top = related.first
    score = top.respond_to?(:score) ? top.score : top[:score]
    raise "top hit has no usable score (got #{top.inspect[0, 80]})" if score.nil?
  end

  puts
end

puts '=== Summary ==='
passed = results.count(true)
failed = results.count(false)
puts "passed: #{passed}    failed: #{failed}    stores: #{stores.keys.join(', ')}"
exit(failed.zero? ? 0 : 1)
