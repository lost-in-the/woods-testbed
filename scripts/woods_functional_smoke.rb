# frozen_string_literal: true
# Shared, read-only acceptance check; smaller variants skip before loading models.
require 'json'
require 'yaml'
contract_path = Rails.root.join('functional_contract.yml')
unless contract_path.file?
  puts 'SKIP Canopy functional contract: this variant has no contract'
  exit 0
end
require 'woods/mcp/index_reader'
require 'woods/console/rack_middleware'
require 'woods/console/embedded_executor'
require 'woods/console/safe_context'
require 'woods/console/model_validator'
require 'woods/console/server'
Rails.application.eager_load!
contract = YAML.safe_load_file(contract_path)
reader = Woods::MCP::IndexReader.new(ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods').to_s))
failures = []
checks = 0
check = lambda do |name, &block|
  checks += 1
  raise name unless block.call
  puts "PASS #{name}"
rescue StandardError => error
  failures << "#{name}: #{error.message}"
end
contract.fetch('models').each do |identifier, expected|
  check.call("#{identifier} schema and associations") do
    unit = reader.find_unit(identifier) or raise 'missing unit'
    associations = unit.dig('metadata', 'associations').map { |entry| entry['name'] }
    columns = unit.dig('metadata', 'columns').map { |entry| entry['name'] }
    (expected.fetch('associations', []) - associations).empty? && (expected.fetch('columns', []) - columns).empty?
  end
end
contract.fetch('units').each { |identifier| check.call("unit #{identifier}") { reader.find_unit(identifier) } }
check.call('Article concern inlining') { reader.find_unit('Article')['source_code'].include?('Included from: Archivable') }
check.call('Activity polymorphic subject') { reader.find_unit('ActivityEvent').dig('metadata', 'associations').any? { |a| a['name'] == 'subject' && a['polymorphic'] } }
check.call('Collection through association') { reader.find_unit('Collection').dig('metadata', 'associations').any? { |a| a['name'] == 'articles' && a['through'] == 'collection_articles' } }
check.call('Publishing dependencies') do
  targets = reader.find_unit('PublishArticle').fetch('dependencies').map { |d| d['target'] }
  %w[Article PublishArticleJob].all? { |target| targets.include?(target) }
end
contract.fetch('retrieval').each do |probe|
  check.call(probe.fetch('question')) do
    result = reader.search(probe.fetch('pattern'), limit: 10)
    entries = result.is_a?(Hash) ? result.fetch(:results) { result.fetch('results') } : result
    entries.any? { |entry| (entry['identifier'] || entry[:identifier]) == probe.fetch('expected') }
  end
end

middleware = Woods::Console::RackMiddleware.new(->(_env) { [200, {}, []] }, embedded_read_tools: true)
introspection = middleware.send(:build_model_introspection)
safe_context = Woods::Console::SafeContext.new(pool: ActiveRecord::Base.connection_pool, redacted_columns: Woods.configuration.console_redacted_columns)
executor = Woods::Console::EmbeddedExecutor.new(
  model_validator: Woods::Console::ModelValidator.new(registry: introspection[:registry], table_names: introspection[:tables]),
  safe_context: safe_context,
  connection: ActiveRecord::Base.connection, read_tools_enabled: true
)
query = lambda do |sql|
  response = executor.send_request('tool' => 'sql', 'params' => { 'sql' => sql, 'limit' => 100 })
  raise response.inspect unless response['ok']
  Woods::Console::Server.send(:apply_redaction, response.fetch('result'), safe_context).fetch('rows')
end
check.call('Console overdue invoice joins have a known answer') do
  query.call("SELECT SUM(li.amount_cents) FROM billing_line_items li JOIN billing_invoices i ON i.id = li.invoice_id WHERE i.reference = 'CANOPY-OVERDUE'") == [[2500]]
end
check.call('Console partial refund totals have a known answer') do
  query.call("SELECT SUM(r.amount_cents) FROM billing_refunds r JOIN billing_payments p ON p.id = r.payment_id JOIN billing_invoices i ON i.id = p.invoice_id WHERE i.reference = 'CANOPY-REFUND'") == [[300]]
end
check.call('Console revision history keeps rejection and approval') do
  rows = query.call("SELECT d.outcome FROM review_decisions d JOIN review_assignments a ON a.id = d.review_assignment_id JOIN article_revisions r ON r.id = a.article_revision_id JOIN articles ON articles.id = r.article_id WHERE articles.slug = 'canopy-story-0' ORDER BY r.number")
  rows == [['changes_requested'], ['approved']]
end
check.call('Console bounded nested JSON') do
  result = executor.send_request('tool' => 'sample', 'params' => { 'model' => 'Subscriber', 'limit' => 2 })
  result['ok'] && result.dig('result', 'records').size == 2 && result.to_json.include?('accessibility')
end
check.call('Console Unicode text round trip') do
  query.call("SELECT body FROM articles WHERE slug = 'canopy-story-0'").flatten.first.include?('Café')
end
check.call('Console webhook secrets are redacted') do
  rows = query.call('SELECT secret FROM webhook_endpoints')
  rows.any? && rows.flatten.all? { |value| value == '[REDACTED]' }
end
check.call('Console rejects writes') do
  response = executor.send_request('tool' => 'sql', 'params' => { 'sql' => "DELETE FROM articles" })
  !response['ok'] && response['error_type'] == 'validation'
end
if Testbed::Dataset.manifest_path.file?
  manifest = JSON.parse(Testbed::Dataset.manifest_path.read)
  if manifest['profile'] == 'smoke'
    contract.fetch('smoke_reports').each do |slug, expected|
      check.call("fixed smoke reports for #{slug}") do
        report = EditorialReport.new(Organization.find_by!(slug: slug), at: Time.zone.parse(manifest.fetch('reference_time')))
        report.review_backlog.count == expected['review_backlog'] && report.overdue_cents == expected['overdue_cents'] && report.newsletter_outcomes == expected['newsletter']
      end
    end
  end
end
puts "#{checks - failures.size}/#{checks} functional checks passed"
failures.each { |failure| warn "FAIL #{failure}" }
exit(failures.empty? ? 0 : 1)
