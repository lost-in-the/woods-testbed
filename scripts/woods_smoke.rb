# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_smoke.rb
#
# Smoke-tests the four PR 34 pre-merge fixes and the G-1 wrapper naming fix
# against a real Rails boot. Version-agnostic: the header prints the detected
# Rails version so output clearly reflects whichever variant invoked it.
#   1. RackMiddleware#build_embedded_server uses connection_pool.with_connection
#      (no AR::Base.connection deprecation).
#   2. TableGate rejects double-quoted schema-qualified identifiers.
#   3. TableGate rejects MySQL STRAIGHT_JOIN.
#   4. TableGate's blocked_tables symmetry — bare entries are wildcards,
#      schema-qualified entries are schema-specific.
#   5. G-1 wrapper fixtures: both files under app/services/domain/container/
#      extract as their governed inner classes (Domain::Container::Parser,
#      Domain::Container::Renderer) — as distinct units, never collapsed onto
#      the wrapper — and an incremental run of one wrapper file preserves
#      both. Variants without the fixtures skip this section.

require 'woods/console/rack_middleware'
require 'woods/console/server'
require 'woods/console/table_gate'

results = []

def assert(name, &block)
  block.call
  puts "  PASS  #{name}"
  true
rescue StandardError => e
  puts "  FAIL  #{name}: #{e.class}: #{e.message}"
  false
end

puts '=== Rails environment ==='
puts "Rails:           #{Rails.version}"
puts "ActiveRecord:    #{ActiveRecord::VERSION::STRING}"
puts "Ruby:            #{RUBY_VERSION}"
puts "AR adapter:      #{ActiveRecord::Base.connection_pool.with_connection(&:adapter_name)}"
puts

# ── Section 1: RackMiddleware boots without invoking AR::Base.connection ──

puts '=== Section 1: middleware boot uses connection_pool.with_connection ==='

calls_to_deprecated = 0
ActiveRecord::Base.singleton_class.prepend(Module.new do
  define_method(:connection) do
    Thread.current[:_woods_smoke_calls_to_deprecated] = (Thread.current[:_woods_smoke_calls_to_deprecated] || 0) + 1
    super()
  end
end)

Thread.current[:_woods_smoke_calls_to_deprecated] = 0
mw = Woods::Console::RackMiddleware.new(->(_env) { [200, {}, []] })
server = mw.send(:build_embedded_server)
calls_to_deprecated = Thread.current[:_woods_smoke_calls_to_deprecated] || 0

results << assert('RackMiddleware#build_embedded_server returns a server') { raise 'nil server' if server.nil? }
results << assert('build_embedded_server never invoked the deprecated AR::Base.connection') do
  raise "called .connection #{calls_to_deprecated} time(s)" unless calls_to_deprecated.zero?
end

# ── Section 2: TableGate bypass regressions ──

puts
puts '=== Section 2: TableGate bypass regressions ==='

gate_users = Woods::Console::TableGate.new(blocked_tables: %w[users], model_tables: {})

results << assert('rejects "public"."users" (Eileen bypass #1)') do
  gate_users.check_sql!('SELECT * FROM "public"."users"')
  raise 'expected TableGateError'
rescue Woods::Console::TableGateError
  # expected
end

results << assert('rejects `app`.`users` (Eileen bypass #1, MySQL form)') do
  gate_users.check_sql!('SELECT * FROM `app`.`users`')
  raise 'expected TableGateError'
rescue Woods::Console::TableGateError
  # expected
end

results << assert('rejects MySQL STRAIGHT_JOIN users (Eileen bypass #2)') do
  gate_users.check_sql!('SELECT * FROM x STRAIGHT_JOIN users ON x.id = users.id')
  raise 'expected TableGateError'
rescue Woods::Console::TableGateError
  # expected
end

# ── Section 3: blocked_tables symmetry (Eileen bypass #3) ──

puts
puts '=== Section 3: blocked_tables symmetry ==='

gate_audit = Woods::Console::TableGate.new(blocked_tables: %w[audit.users], model_tables: {})

results << assert('audit.users entry rejects FROM audit.users') do
  gate_audit.check_sql!('SELECT * FROM audit.users')
  raise 'expected TableGateError'
rescue Woods::Console::TableGateError
  # expected
end

results << assert('audit.users entry rejects FROM "audit"."users"') do
  gate_audit.check_sql!('SELECT * FROM "audit"."users"')
  raise 'expected TableGateError'
rescue Woods::Console::TableGateError
  # expected
end

results << assert('audit.users entry does NOT reject FROM public.users (schema-specific)') do
  gate_audit.check_sql!('SELECT * FROM public.users')
end

results << assert('audit.users entry does NOT reject bare FROM users') do
  gate_audit.check_sql!('SELECT * FROM users')
end

results << assert('bare users entry rejects FROM public.users (wildcard preserved)') do
  gate_users.check_sql!('SELECT * FROM public.users')
  raise 'expected TableGateError'
rescue Woods::Console::TableGateError
  # expected
end

# ── Section 4: G-1 wrapper fixtures — governed naming, full vs incremental ──

# Index summaries for one output dir: identifier => { 'type_dirs' => [...],
# 'file_path' => '...' }. Same read path as woods_contract_smoke.rb: the gem
# publishes under payloads/gen-N/ and names the current one in
# generation.json; older gems wrote a flat index. A missing or empty index
# simply yields an empty hash — the assertions below say so precisely.
def woods_smoke_index_summaries(output_dir)
  payload_dir =
    begin
      require 'woods/generation'
      Woods::Generation.new(output_dir: output_dir).payload_dir
    rescue LoadError, NameError
      Pathname.new(output_dir.to_s)
    end

  summaries = {}
  payload_dir.children.select(&:directory?).each do |dir|
    index_file = dir.join('_index.json')
    next unless index_file.file?

    JSON.parse(index_file.read).each do |entry|
      id = entry['identifier'].to_s
      if (known = summaries[id])
        known['type_dirs'] << dir.basename.to_s
      else
        summaries[id] = { 'type_dirs' => [dir.basename.to_s], 'file_path' => entry['file_path'].to_s }
      end
    end
  end
  summaries
end

parser_path   = Rails.root.join('app/services/domain/container/parser.rb')
renderer_path = Rails.root.join('app/services/domain/container/renderer.rb')

if parser_path.file? && renderer_path.file?
  puts
  puts '=== Section 4: G-1 wrapper fixtures — distinct child identifiers ==='

  output_dir = ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods').to_s)

  # Extraction logs at info; silence it so the smoke output stays readable.
  # Process-local: this runner exits when the script does.
  Rails.logger.level = Logger::ERROR if Rails.logger.respond_to?(:level=)
  require 'woods/extractor'

  results << assert('full extraction completes') do
    Woods::Extractor.new(output_dir: output_dir).extract_all
  end

  full = woods_smoke_index_summaries(output_dir)

  results << assert('full extraction reports Domain::Container::Parser (not the wrapper)') do
    summary = full['Domain::Container::Parser']
    raise 'not in the index' if summary.nil?

    raise "at #{summary['file_path']}" unless summary['file_path'].end_with?('/parser.rb')
  end

  results << assert('full extraction reports Domain::Container::Renderer (not the wrapper)') do
    summary = full['Domain::Container::Renderer']
    raise 'not in the index' if summary.nil?

    raise "at #{summary['file_path']}" unless summary['file_path'].end_with?('/renderer.rb')
  end

  results << assert('both children are distinct units — dedup did not collapse them') do
    parser_summary   = full['Domain::Container::Parser']
    renderer_summary = full['Domain::Container::Renderer']
    raise 'Parser missing' if parser_summary.nil?
    raise 'Renderer missing' if renderer_summary.nil?

    raise "both map to #{parser_summary['file_path']}" if parser_summary['file_path'] == renderer_summary['file_path']
  end

  results << assert('neither fixture file is indexed as the bare wrapper Domain::Container') do
    summary = full['Domain::Container']
    next if summary.nil?

    file = summary['file_path']
    raise "indexed as bare wrapper at #{file}" if file.end_with?('/parser.rb', '/renderer.rb')
  end

  # Incremental leg. The sibling's content is unchanged; the point is the
  # dispatch — governed naming must survive re-extraction of one wrapper
  # file and the publish that follows.
  results << assert('incremental re-extract of parser.rb re-issues the governed child') do
    File.utime(Time.now, Time.now, parser_path)
    touched = Woods::Extractor.new(output_dir: output_dir)
                              .extract_changed(['app/services/domain/container/parser.rb'])
    raise "touched #{touched.inspect}" unless touched.include?('Domain::Container::Parser')
  end

  incremental = woods_smoke_index_summaries(output_dir)

  results << assert('after incremental, Parser still a distinct child (no collapse)') do
    summary = incremental['Domain::Container::Parser']
    raise 'lost from the index' if summary.nil?

    raise "at #{summary['file_path']}" unless summary['file_path'].end_with?('/parser.rb')
  end

  results << assert('after incremental, Renderer still a distinct child (no loss)') do
    summary = incremental['Domain::Container::Renderer']
    raise 'lost from the index' if summary.nil?

    raise "at #{summary['file_path']}" unless summary['file_path'].end_with?('/renderer.rb')
  end

  results << assert('after incremental, neither fixture file is still the bare wrapper') do
    summary = incremental['Domain::Container']
    next if summary.nil?

    file = summary['file_path']
    raise "indexed as bare wrapper at #{file}" if file.end_with?('/parser.rb', '/renderer.rb')
  end
else
  puts
  puts '=== Section 4: G-1 wrapper fixtures — skipped (no Domain::Container fixtures in this variant) ==='
end

# ── Summary ──

puts
puts '=== Summary ==='
passed = results.count(true)
failed = results.count(false)
puts "passed: #{passed}    failed: #{failed}    total: #{results.size}"
exit(failed.zero? ? 0 : 1)
