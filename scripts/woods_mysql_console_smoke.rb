# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_mysql_console_smoke.rb
#
# Executes the MySQL dialect lock-clause contract (gem PR
# lost-in-the/woods#248) through the production Console query path against a
# live MySQL server. The executor is built exactly the way RackMiddleware
# builds it for the packaged Console — real model introspection, the real
# ActiveRecord connection pool inside SafeContext's rolled-back transaction,
# read tools enabled — and reached through the same send_request entry the
# DispatchPipeline funnels into.
#
# Why a dedicated lane: the SQLite-backed variants only run
# SqlValidator#valid? against a string, so no variant without a mysql2 handle
# can tell an adapter-wiring regression apart from a validator fix — the fast
# check could pass while the packaged Console still ships the locked statement
# to MySQL. Here the statement goes through the full production path to a real
# MySQL server, and a recording wrapper around the live adapter proves the
# refused statement executes ZERO queries while a benign SELECT executes
# normally.
#
# Variants without a MySQL adapter skip cleanly: scripts/ runs against every
# variant, and only rails-6.0-mysql carries a mysql2 handle.
#
# Contract-first: expected RED against gem main today — the statement is
# accepted by the validator and executed against MySQL — until gem PR
# lost-in-the/woods#248 merges.
#
# Exit codes:
#   0  contract holds (or this variant has no MySQL adapter)
#   1  contract violated

require 'woods/console/embedded_executor'
require 'woods/console/model_validator'
require 'woods/console/rack_middleware'
require 'woods/console/safe_context'

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
puts "Rails:      #{Rails.version}"
puts "Adapter:    #{ActiveRecord::Base.connection.adapter_name}"
puts

# ── Skip cleanly on non-MySQL variants ────────────────────────────────────

adapter_name = ActiveRecord::Base.connection.adapter_name.to_s.downcase
unless adapter_name.include?('mysql')
  puts "No MySQL adapter on this variant (#{adapter_name}) — nothing to check here."
  exit 0
end

# ── Record every statement the production path sends to the adapter ───────
# Extends the live connection object, so everything SafeContext and the
# executor do still runs against the real MySQL server; the recording is
# transparent. The benign probe later proves the recording saw a real
# execution, so a broken wrapper cannot fake a zero-execution pass.

executed_sql = []
recorder = Module.new do
  define_method(:execute) do |sql, *rest|
    executed_sql << sql
    super(sql, *rest)
  end

  define_method(:select_all) do |sql, *rest, **kwargs, &block|
    executed_sql << sql
    super(sql, *rest, **kwargs, &block)
  end
end
ActiveRecord::Base.connection.extend(recorder)

# ── Production Console wiring (mirrors RackMiddleware#build_embedded_server)
# RackMiddleware#build_model_introspection is private; send matches the
# existing house precedent (woods_smoke.rb uses it the same way).

middleware = Woods::Console::RackMiddleware.new(->(_env) { [200, {}, []] },
                                                embedded_read_tools: true)
introspection = middleware.send(:build_model_introspection)

executor = Woods::Console::EmbeddedExecutor.new(
  model_validator: Woods::Console::ModelValidator.new(registry: introspection[:registry],
                                                      table_names: introspection[:tables]),
  safe_context: Woods::Console::SafeContext.new(pool: ActiveRecord::Base.connection_pool),
  connection: ActiveRecord::Base.connection,
  read_tools_enabled: true
)

results << assert('production Console executor builds over the real MySQL pool') do
  raise 'nil executor' if executor.nil?
end

# ── The contract ──────────────────────────────────────────────────────────

MYSQL_LOCK_STATEMENT = "SELECT * FROM users LOCK # mysql comment\nIN SHARE MODE"

results << assert('benign SELECT executes through the real MySQL adapter') do
  response = executor.send_request({ 'tool' => 'sql', 'params' => { 'sql' => 'SELECT 1 AS one' } })
  raise "expected ok response, got #{response.inspect[0, 300]}" unless response['ok']
  raise 'no rows in the result' unless response.dig('result', 'rows')

  unless executed_sql.any? { |sql| sql.include?('SELECT 1 AS one') }
    raise 'benign SELECT never reached the adapter — the recording wrapper is broken'
  end
end

results << assert('locked SELECT is refused with a typed validation error') do
  response = executor.send_request({ 'tool' => 'sql', 'params' => { 'sql' => MYSQL_LOCK_STATEMENT } })

  if response['ok']
    raise 'the lock statement was executed against MySQL (accepted by the validator)'
  end

  unless response['error_type'] == 'validation'
    raise "refusal is not typed validation: #{response['error_type'].inspect}"
  end

  next if response['error'].to_s.match?(/lock/i)

  raise "refusal does not name the lock clause: #{response['error'].inspect}"
end

results << assert('refused statement executes ZERO queries on the adapter') do
  leaked = executed_sql.select { |sql| sql.include?('mysql comment') }
  raise "the lock statement reached the adapter: #{leaked.inspect[0, 300]}" unless leaked.empty?
end

# ── Summary ──

puts
puts '=== Summary ==='
passed = results.count(true)
failed = results.count(false)
puts "passed: #{passed}    failed: #{failed}    total: #{results.size}"
exit(failed.zero? ? 0 : 1)
