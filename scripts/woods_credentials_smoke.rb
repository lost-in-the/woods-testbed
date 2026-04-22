# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_credentials_smoke.rb
#
# Exercises the Console MCP server's response-shaping pipeline against
# documented test credentials from common Rails-app providers and asserts
# that no raw credential value escapes through any of the Tier 1 read tools.
#
# Pipeline replicated here is the SAME 3-line flow Server#send_to_bridge runs
# in production:
#   1. EmbeddedExecutor#send_request  (executes inside a rolled-back txn)
#   2. apply_redaction(result, safe_ctx)  (Layer 3 — column + EAV redaction)
#   3. credential_scanner.scan(result)    (Layer 2 — pattern-based redaction)
#
# Layers 1 (TableGate), 4 (column/EAV redaction operator-config), and 5
# (rolled-back transaction) are exercised by the previous smoke
# (woods_smoke.rb) and the unit suite respectively.

require 'json'
require 'set'
require 'woods/console/embedded_executor'
require 'woods/console/safe_context'
require 'woods/console/credential_scanner'
require 'woods/console/server'
require 'woods/console/model_validator'

# Load the seed list — same fixtures used to populate the DB.
load Rails.root.join('db/seeds/credentials.rb').to_s

# Reload to get the live data (seeds delete_all + recreate).
load Rails.root.join('db/seeds/credentials.rb').to_s if Credential.count.zero?

# ── Pipeline construction ────────────────────────────────────────────────

# Layer 5 — rolled-back transaction wrapper used during execution.
exec_safe_ctx = ActiveRecord::Base.connection_pool.with_connection do |conn|
  Woods::Console::SafeContext.new(connection: conn)
end

# Layer 3 — column redaction. Empty by default so we can prove the scanner
# alone catches what it can; later we rebuild this with `value` and
# `metadata` redacted to plug the gap for providers the scanner can't see.
def build_redaction_ctx(redacted_columns: [], redacted_key_values: [])
  return nil if redacted_columns.empty? && redacted_key_values.empty?

  ActiveRecord::Base.connection_pool.with_connection do |conn|
    Woods::Console::SafeContext.new(
      connection: conn,
      redacted_columns: redacted_columns,
      redacted_key_values: redacted_key_values
    )
  end
end

# Layer 2 — credential pattern scanner.
scanner = Woods::Console::CredentialScanner.new

# Embedded executor wired with model validation so console_query/recent/etc.
# accept the Credential model.
validator = Woods::Console::ModelValidator.new(
  registry: { 'Credential' => Credential.column_names }
)
executor = Woods::Console::EmbeddedExecutor.new(
  model_validator: validator,
  safe_context: exec_safe_ctx,
  read_tools_enabled: true
)

# Replicate Server#apply_redaction — the redaction shape-walker is private,
# but it is the canonical Layer 3 dispatcher. We re-use it via send so the
# harness exercises the production code, not a re-implementation.
def apply_layer3(result, safe_ctx)
  return result unless safe_ctx

  Woods::Console::Server.send(:apply_redaction, result, safe_ctx)
end

# Run a single tool through the full Layer 3 → Layer 2 pipeline and return
# the final response payload as a Ruby object (so assertions can inspect
# nested hashes/arrays directly).
def run_tool(executor, tool, params, redaction_ctx, scanner)
  response = executor.send_request('tool' => tool, 'params' => params)
  raise "tool failed: #{response['error']}" unless response['ok']

  result = response['result']
  result = apply_layer3(result, redaction_ctx)
  scanned, _counts = scanner.scan(result)
  scanned
end

# Convert any Ruby value into a flat string for substring leak detection.
def flatten_to_text(value)
  JSON.generate(value)
rescue StandardError
  value.to_s
end

# ── Test cases ───────────────────────────────────────────────────────────

results = []

CREDENTIAL_FIXTURES.each do |fixture|
  rows = Credential.where(provider: fixture[:provider], key_type: fixture[:key_type])
  next if rows.empty?

  rows.each do |credential|
    raw   = credential.value
    label = "#{fixture[:provider]}/#{fixture[:key_type]}"

    # Five different Tier 1 read tools — each returns a different shape.
    tool_calls = [
      ['recent',  { 'model' => 'Credential', 'order_by' => 'id', 'limit' => 50 }],
      ['find',    { 'model' => 'Credential', 'id' => credential.id }],
      ['sample',  { 'model' => 'Credential', 'limit' => 25 }],
      ['pluck',   { 'model' => 'Credential', 'columns' => %w[provider value notes metadata] }],
      ['query',   { 'model' => 'Credential', 'scope' => { 'provider' => fixture[:provider] }, 'limit' => 5 }]
    ]

    tool_calls.each do |tool, params|
      payload = run_tool(executor, tool, params, nil, Woods::Console::CredentialScanner.new)
      text    = flatten_to_text(payload)

      leaked      = text.include?(raw)
      sanitised   = text.include?('[REDACTED]')
      should_redact = fixture[:detected]

      verdict =
        if should_redact && !leaked then 'PASS'
        elsif !should_redact && leaked then 'GAP-EXPECTED'
        elsif !should_redact && !leaked then 'PASS-COVERAGE-EXTENDED'
        else 'LEAK'
        end

      results << {
        provider: fixture[:provider],
        key_type: fixture[:key_type],
        tool: tool,
        verdict: verdict,
        leaked: leaked,
        sanitised: sanitised
      }
    end
  end
end

# ── Gap-plug demo: column redaction (`value`+`metadata`) and EAV ─────────
# `value` covers the column itself; `metadata` covers the JSON blob where
# we mirrored the credential. EAV redaction additionally targets rows where
# `key_type` matches a sensitive name, regardless of value contents.
gap_results = []
gap_ctx = build_redaction_ctx(
  redacted_columns: %w[value metadata],
  redacted_key_values: [
    { key_column: 'key_type', value_column: 'value',
      sensitive_keys: %w[api_key server_token uuid_token push_api_key] }
  ]
)

CREDENTIAL_FIXTURES.reject { |f| f[:detected] }.each do |fixture|
  cred = Credential.find_by(provider: fixture[:provider], key_type: fixture[:key_type])
  next unless cred

  payload = run_tool(executor, 'find', { 'model' => 'Credential', 'id' => cred.id },
                     gap_ctx, Woods::Console::CredentialScanner.new)
  text = flatten_to_text(payload)
  gap_results << {
    provider: fixture[:provider],
    key_type: fixture[:key_type],
    plugged: !text.include?(cred.value)
  }
end

# ── Report ───────────────────────────────────────────────────────────────

def fmt(verdict)
  case verdict
  when 'PASS', 'PASS-COVERAGE-EXTENDED' then "  #{verdict}"
  when 'GAP-EXPECTED'                   then "  #{verdict} (no scanner pattern — needs Layer 3)"
  else                                       "  #{verdict} ⚠"
  end
end

puts "=== Credential leak harness — Rails #{Rails.version} / Console MCP ==="
puts
puts format('%-22s %-18s %-10s %s', 'PROVIDER/KEY_TYPE', 'TOOL', 'VERDICT', '')
puts '-' * 80

results.group_by { |r| "#{r[:provider]}/#{r[:key_type]}" }.each do |label, rows|
  rows.each do |r|
    puts format('%-22s %-18s %s', label, r[:tool], fmt(r[:verdict]))
  end
end

puts
puts '=== Layer-3 column-redaction gap plug (uncovered providers) ==='
gap_results.each do |g|
  status = g[:plugged] ? 'PLUGGED' : 'STILL LEAKING'
  puts format('  %-22s %s', "#{g[:provider]}/#{g[:key_type]}", status)
end

# ── Exit signaling ───────────────────────────────────────────────────────

actual_leaks      = results.count { |r| r[:verdict] == 'LEAK' }
expected_gaps     = results.count { |r| r[:verdict] == 'GAP-EXPECTED' }
covered_passes    = results.count { |r| r[:verdict] == 'PASS' }
plug_failures     = gap_results.count { |g| !g[:plugged] }

puts
puts '=== Summary ==='
puts "covered providers x tools sealed by Layer 2:  #{covered_passes}"
puts "uncovered providers leaking through Layer 2 (expected): #{expected_gaps}"
puts "uncovered providers plugged by Layer 3 column redaction: #{gap_results.count(&:itself) - plug_failures}"
puts "actual leaks (must be zero): #{actual_leaks}"
puts "Layer 3 plug failures (must be zero): #{plug_failures}"

exit((actual_leaks + plug_failures).zero? ? 0 : 1)
