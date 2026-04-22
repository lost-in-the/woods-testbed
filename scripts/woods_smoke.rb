# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_smoke.rb
#
# Smoke-tests the four PR 34 pre-merge fixes against a real Rails boot.
# Version-agnostic: the header prints the detected Rails version so output
# clearly reflects whichever variant invoked it.
#   1. RackMiddleware#build_embedded_server uses connection_pool.with_connection
#      (no AR::Base.connection deprecation).
#   2. TableGate rejects double-quoted schema-qualified identifiers.
#   3. TableGate rejects MySQL STRAIGHT_JOIN.
#   4. TableGate's blocked_tables symmetry — bare entries are wildcards,
#      schema-qualified entries are schema-specific.

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

# ── Summary ──

puts
puts '=== Summary ==='
passed = results.count(true)
failed = results.count(false)
puts "passed: #{passed}    failed: #{failed}    total: #{results.size}"
exit(failed.zero? ? 0 : 1)
