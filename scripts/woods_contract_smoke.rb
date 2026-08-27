# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_contract_smoke.rb
#
# Asserts that a variant's extracted index conforms to its kernel_contract.yml.
#
# Why this exists: the kernel's value is the *edges* between its files — a
# concern inlined into three models, a view template whose route helper resolves
# to a controller, a use case that reaches a model. A per-type "is this
# directory non-empty" check passes happily on 34 disconnected islands, which is
# exactly the fixture that tests no fan-out at all. This checks the edges.
#
# It also keeps a human off the critical path: the kernel contract was
# originally gated on review, and encoding it here makes the gate a command with
# an exit code.
#
# Index layout this reads (verified against real output, not assumed):
#   <output>/manifest.json          counts per type
#   <output>/<type_dir>/_index.json [{identifier, file_path, ...}] — no type field
#   <output>/<type_dir>/<Ident>_<hash>.json   the full unit, with metadata
#   <output>/dependency_graph.json  {"edges": {ident => [{target:, via:}]}}
#
# Variants with no kernel_contract.yml skip cleanly — scripts/ is mounted into
# every variant, and only the large one carries a contract.
#
# Expect this to FAIL until the kernel is built (rungs 4-7 of
# docs/plans/002-loop.md). A precise list of what is missing is the intended
# output, not an error.
#
# Exit codes:
#   0  conformant (or no contract on this variant)
#   1  no index — run `bin/rails woods:extract` first
#   2  one or more contract violations, listed

require 'yaml'
require 'json'

CONTRACT_PATH = Rails.root.join('kernel_contract.yml')
INDEX_DIR     = Pathname.new(ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods').to_s))

# Woods 2.0 publishes each generation under payloads/gen-N/ and names the
# current one in generation.json; older gems wrote a flat index. Resolve the
# same way the gem does so this script reads whichever layout is on disk.
PAYLOAD_DIR = begin
  require 'woods/generation'
  Woods::Generation.new(output_dir: INDEX_DIR).payload_dir
rescue LoadError, NameError
  INDEX_DIR
end

unless CONTRACT_PATH.file?
  puts "No kernel_contract.yml in #{Rails.root} — nothing to check for this variant."
  exit 0
end

unless PAYLOAD_DIR.join('manifest.json').file?
  warn "No index at #{INDEX_DIR}. Run `bin/rails woods:extract` first."
  exit 1
end

contract = YAML.safe_load_file(CONTRACT_PATH, aliases: true)
manifest = JSON.parse(PAYLOAD_DIR.join('manifest.json').read)
graph    = JSON.parse(PAYLOAD_DIR.join('dependency_graph.json').read)
counts   = manifest['counts'] || {}
edges    = graph['edges'] || {}

violations = []
checks     = 0

def violation(list, message)
  list << message
end

# ── Unit table ────────────────────────────────────────────────────────────
# Built from every type directory's _index.json. The summaries carry no `type`
# field — the directory is the type — so it is attached here.
#
# Directory names are plural and type names singular; rather than hardcode an
# inflection table that would drift, the directory name is kept alongside and
# both are matched when a type is looked up.
summaries = {} # identifier => { type_dir:, identifier:, file_path: }

PAYLOAD_DIR.children.select(&:directory?).each do |dir|
  index_file = dir.join('_index.json')
  next unless index_file.file?

  JSON.parse(index_file.read).each do |entry|
    id = entry['identifier'].to_s
    existing = summaries[id]

    if existing
      existing['type_dirs'] << dir.basename.to_s
    else
      summaries[id] = {
        'type_dirs' => [dir.basename.to_s],
        'identifier' => id,
        'file_path' => entry['file_path'].to_s,
        'dir' => dir
      }
    end
  end
rescue JSON::ParserError => e
  violation(violations, "#{index_file}: unreadable (#{e.message})")
end

# Full unit JSON, loaded only when an assertion needs metadata. The filename is
# <Identifier>_<hash>.json with the identifier's namespace separators replaced,
# so it is found by globbing rather than by reconstructing the hash.
def load_unit(summary)
  return nil unless summary

  stem = summary['identifier'].gsub(/[:.\/]/, '_')
  match = Dir[summary['dir'].join("#{stem}_*.json").to_s].first
  match ? JSON.parse(File.read(match)) : nil
rescue JSON::ParserError
  nil
end

def summary_for(summaries, name)
  summaries[name.to_s]
end

# ── Models, namespaces, STI ───────────────────────────────────────────────
models = contract['models'] || {}
(Array(models['plain']) + Array(models['namespaced'])).each do |name|
  checks += 1
  summary = summary_for(summaries, name)
  next violation(violations, "model #{name}: not in the index") if summary.nil?

  unless summary['type_dirs'].include?('models')
    violation(violations, "model #{name}: extracted into #{summary['type_dirs'].join('/')}, expected models")
  end
end

if (sti = contract['sti'])
  checks += 1
  base = summary_for(summaries, sti['base'])
  if base.nil?
    violation(violations, "STI base #{sti['base']}: not in the index")
  else
    unit = load_unit(base)
    unless unit&.dig('metadata', 'is_sti_base')
      violation(violations, "STI base #{sti['base']}: metadata.is_sti_base is not true")
    end
  end

  Array(sti['subclasses']).each do |sub|
    checks += 1
    summary = summary_for(summaries, sub)
    next violation(violations, "STI subclass #{sub}: not in the index") if summary.nil?

    unit = load_unit(summary)
    next violation(violations, "STI subclass #{sub}: unit file unreadable") if unit.nil?

    violation(violations, "STI subclass #{sub}: metadata.is_sti_child is not true") unless unit.dig('metadata', 'is_sti_child')

    parent = unit.dig('metadata', 'parent_class').to_s
    violation(violations, "STI subclass #{sub}: parent_class is #{parent.inspect}, expected #{sti['base']}") if parent != sti['base'].to_s
  end
end

Array(contract['poros']).each do |poro|
  checks += 1
  summary = summary_for(summaries, poro['class'])
  next violation(violations, "poro #{poro['class']}: not in the index") if summary.nil?

  unless summary['type_dirs'].include?('poros')
    violation(violations, "poro #{poro['class']}: extracted into #{summary['type_dirs'].join('/')}, expected poros")
  end
end

# ── Concern inlining ──────────────────────────────────────────────────────
# Asserted from the *including model's* side via metadata.inlined_concerns, not
# from the concern unit. Inlining is the gem's headline differentiator, so the
# meaningful question is "did this concern's source reach the model", which only
# the model's metadata answers. The count is exact: a concern that quietly loses
# an include still extracts fine and still shows a non-empty type, and this is
# the only check that would notice.
Array(contract['concerns']).each do |concern|
  name = concern['name']
  expected = Array(concern['included_by'])

  checks += 1
  violation(violations, "concern #{name}: not in the index") unless summary_for(summaries, name)

  actual = []
  expected.each do |includer|
    checks += 1
    summary = summary_for(summaries, includer)
    next violation(violations, "concern #{name}: includer #{includer} not in the index") if summary.nil?

    unit = load_unit(summary)
    next violation(violations, "concern #{name}: includer #{includer} unit unreadable") if unit.nil?

    declared = Array(unit.dig('metadata', 'inlined_concerns')) +
               Array(unit.dig('metadata', 'included_concerns'))
    inlined = declared.map do |c|
      c.is_a?(Hash) ? (c['name'] || c['identifier']).to_s : c.to_s
    end

    if inlined.include?(name.to_s)
      actual << includer
    else
      violation(violations, "concern #{name}: not inlined into #{includer} " \
                            "(inlined_concerns: #{inlined.empty? ? 'none' : inlined.join(', ')})")
    end
  end

  next if actual.size == expected.size

  violation(violations, "concern #{name}: inlined into #{actual.size} of #{expected.size} declared models")
end

# ── Services in the non-standard directory ────────────────────────────────
if (services = contract['services'])
  Array(services['classes']).each do |name|
    checks += 1
    summary = summary_for(summaries, name)
    next violation(violations, "service #{name}: not in the index") if summary.nil?

    unless summary['file_path'].include?(services['directory'].to_s)
      violation(violations, "service #{name}: at #{summary['file_path']}, expected under #{services['directory']}")
    end
  end
end

# ── Navigation edges ──────────────────────────────────────────────────────
# The point of the whole contract. A missing edge means a route helper in a
# template did not resolve to its controller — the failure the kernel exists to
# be able to detect.
NAV_VIA = %w[link_to redirect_to form_action].freeze

Array(contract['navigation_edges']).each do |edge|
  checks += 1
  source = edge['from'].to_s
  target = edge['to'].to_s

  summary = summaries.values.find { |s| s['file_path'].end_with?(source) }
  next violation(violations, "navigation edge from #{source}: no unit for that template") if summary.nil?

  outgoing = Array(edges[summary['identifier']])
  matched = outgoing.any? do |e|
    e.is_a?(Hash) && e['target'].to_s == target && NAV_VIA.include?(e['via'].to_s)
  end

  next if matched

  violation(violations, "navigation edge #{source} -> #{target}: absent " \
                        "(helpers: #{Array(edge['helpers']).join(', ')})")
end

# ── Events ────────────────────────────────────────────────────────────────
Array(contract['events']).each do |event|
  checks += 1
  summary = summary_for(summaries, event['name'])
  next violation(violations, "event #{event['name']}: not in the index") if summary.nil?

  unit = load_unit(summary)
  next violation(violations, "event #{event['name']}: unit unreadable") if unit.nil?

  publishers  = Array(unit.dig('metadata', 'publishers')).join(' ')
  subscribers = Array(unit.dig('metadata', 'subscribers')).join(' ')

  violation(violations, "event #{event['name']}: publisher #{event['publisher']} not recorded") unless publishers.include?(File.basename(event['publisher'].to_s))
  violation(violations, "event #{event['name']}: subscriber #{event['subscriber']} not recorded") unless subscribers.include?(File.basename(event['subscriber'].to_s))
end

# ── State machines ────────────────────────────────────────────────────────
Array(contract['state_machines']).each do |sm|
  checks += 1
  found = summaries.values.any? do |s|
    s['type_dirs'].include?('state_machines') && s['identifier'].include?(sm['class'].to_s)
  end
  violation(violations, "state machine on #{sm['class']}: no state_machine unit") unless found
end

# ── One exemplar per remaining type ───────────────────────────────────────
(contract['types'] || {}).each do |type, spec|
  checks += 1
  found = counts[type.to_s].to_i
  minimum = spec['min'] || 1
  violation(violations, "type #{type}: #{found} unit(s), contract requires at least #{minimum}") if found < minimum

  next unless (exemplar = spec['exemplar'])

  violation(violations, "type #{type}: exemplar #{exemplar} not in the index") unless summary_for(summaries, exemplar)
end

# ── Policy / pundit_policy discrimination ─────────────────────────────────
# PolicyExtractor and PunditExtractor both scan app/policies and split on method
# shape, so a kernel with only one policy file leaves one type permanently empty.
Array(contract['policies']).each do |policy|
  checks += 1
  summary = summary_for(summaries, policy['class'])

  if summary.nil?
    violation(violations, "#{policy['class']} (#{policy['shape']}-shaped): not in the index")
    next
  end

  expected_dir = policy['expect_type'].to_s == 'pundit_policy' ? 'pundit_policies' : 'policies'
  next if summary['type_dirs'].include?(expected_dir)

  violation(violations, "#{policy['class']} (#{policy['shape']}-shaped): landed in " \
                        "#{summary['type_dirs'].join('/')}, expected #{expected_dir} — check the " \
                        'method names still match the extractor pattern')
end

# ── Sql guardrails against the real gem classes ──────────────────────────
# Contract-first, like the encoding smoke: these assert console-SQL behaviour
# the gem's remediation PR is adding, so expect FAILs with a precise list
# until the fix lands. Unit level by design — this script never opens a
# database connection, so lock-mode rejections are asserted against
# SqlValidator and redaction refusals against the executor's select
# expression validator, backed by a registry ModelValidator (the same shape
# the gem's own executor specs use).
begin
  require 'woods/console/embedded_executor'
  require 'woods/console/model_validator'
  require 'woods/console/safe_context'
  require 'woods/console/sql_validator'

  sql_validator = Woods::Console::SqlValidator.new

  # Locking clauses read rows under shared/exclusive locks: reads in the
  # English sense, but they take database locks that SafeContext's rollback
  # does not release early, so one console query can stall the app's writes.
  [
    'SELECT * FROM users FOR UPDATE',
    'SELECT * FROM users FOR NO KEY UPDATE',
    'SELECT * FROM users FOR SHARE',
    'SELECT * FROM users FOR UPDATE NOWAIT',
    'SELECT * FROM users LOCK IN SHARE MODE'
  ].each do |sql|
    checks += 1
    violation(violations, "sql guardrail: #{sql} was accepted") if sql_validator.valid?(sql)
  end

  # A data-modifying CTE hidden as the *second* CTE. The writable-CTE scan
  # must see past a benign first CTE; RETURNING makes the write explicit.
  checks += 1
  data_cte = 'WITH a AS (SELECT 1), b AS (DELETE FROM users RETURNING *) SELECT * FROM b'
  violation(violations, "sql guardrail: #{data_cte} was accepted") if sql_validator.valid?(data_cte)

  # The benign shape of the same statement must survive the same scan.
  checks += 1
  benign_cte = 'WITH a AS (SELECT 1), b AS (SELECT 2) SELECT * FROM b'
  unless sql_validator.valid?(benign_cte)
    violation(violations, "sql guardrail: benign multi-CTE SELECT was rejected: #{benign_cte}")
  end

  # Redaction oracle guard, unit level. Aliasing a redacted column renames it
  # in the result set, so the redactor's column-name match misses it and the
  # plaintext escapes through select — the same oracle the redacted-column
  # refusals below exist to close.
  safe_context = Woods::Console::SafeContext.new(connection: nil, redacted_columns: %w[email])
  executor = Woods::Console::EmbeddedExecutor.new(
    model_validator: Woods::Console::ModelValidator.new(registry: { 'User' => %w[id email name] }),
    safe_context: safe_context
  )

  ['email AS contact', 'count(email) AS n'].each do |expr|
    checks += 1
    begin
      executor.send(:validated_select, [expr], 'User')
      violation(violations, "redaction guard: select expression #{expr.inspect} over redacted column 'email' was accepted")
    rescue Woods::Console::ValidationError => e
      unless e.message.match?(/redacted/i)
        violation(violations, "redaction guard: #{expr.inspect} refused for the wrong reason: #{e.message}")
      end
    end
  end

  # The unaliased form stays allowed — SafeContext#redact still owns masking.
  checks += 1
  begin
    kept = executor.send(:validated_select, ['email'], 'User')
    violation(violations, "redaction guard: unaliased redacted column was refused: #{kept.inspect}") unless kept == ['email']
  rescue Woods::Console::ValidationError => e
    violation(violations, "redaction guard: unaliased redacted column was refused: #{e.message}")
  end

  checks += 1
  masked = safe_context.redact('name' => 'Leah', 'email' => 'leah@example.com')
  violation(violations, "redaction guard: redact left redacted 'email' unmasked") unless masked['email'] == '[REDACTED]'
  violation(violations, "redaction guard: redact masked non-redacted 'name'") if masked['name'] != 'Leah'
rescue LoadError, NameError => e
  checks += 1
  violation(violations, "sql guardrails: woods console classes not loadable (#{e.class}: #{e.message})")
end

# ── Partition off known gem issues ────────────────────────────────────────
# A violation matching a known_gem_issues entry is real but not the kernel's
# fault. Reporting it separately keeps the gate meaningful — it can go green on
# what the kernel controls — without hiding the bug or letting the contract
# encode wrong behaviour as expected.
known_specs = Array(contract['known_gem_issues'])
known_hits  = []

violations.reject! do |v|
  spec = known_specs.find { |k| v.include?(k['matches'].to_s) }
  next false unless spec

  known_hits << [v, spec]
  true
end

# ── Report ────────────────────────────────────────────────────────────────
puts '=== Kernel contract conformance ==='
puts "Variant:  #{Rails.application.class.module_parent_name} (#{Rails.root})"
puts "Contract: v#{contract['version']}"
puts "Index:    #{INDEX_DIR} (#{manifest['total_units']} units)"
puts "Checks:   #{checks}"
puts

unless known_hits.empty?
  puts "KNOWN GEM ISSUES  #{known_hits.size} (not counted against the gate):"
  known_hits.each do |(message, spec)|
    puts "  ~ #{message}"
    puts "      #{spec['reason'].to_s.strip.gsub(/\s+/, ' ')}"
    puts "      ref: #{spec['ref']}"
  end
  puts
end

if violations.empty?
  puts "PASS  all #{checks} contract assertions hold " \
       "(#{known_hits.size} known gem issue(s) excluded)."
  exit 0
end

puts "FAIL  #{violations.size} violation(s) across #{checks} checks:"
violations.each { |v| puts "  - #{v}" }
puts
puts 'Expected until the kernel is built — rungs 4-7 of docs/plans/002-loop.md.'
exit 2
