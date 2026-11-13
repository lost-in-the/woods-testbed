# frozen_string_literal: true

# Self-test for woods_shape_profile.rb (plain Ruby, no Rails, no Woods):
#   ruby scripts/tools/woods_shape_profile_self_test.rb
#
# Builds a tiny fake application and index full of identifying strings, runs
# the profiler against it, and asserts that none of them reaches the output,
# that the numbers are right, and that the privacy self-check aborts when a
# string or key gets past the allow-lists.

require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require_relative 'woods_shape_profile'

SCRIPT = File.expand_path('woods_shape_profile.rb', __dir__)

# Every one of these is planted in the fixture; none may appear in a profile.
CANARIES = %w[
  Zyxwv SecretLedgerAccount secret_ledger qq_secret_ledgers iban_number Hushable VaultController
  /hidden/vault open_sesame smuggles_contraband quantum_widget acme_private_gem Quillfeather zeb@acme
  secret-branch deadbeefcafe acme-corp Skunkworks skunkworks_dir mystery_stat ruby-3.3.6-acme Fix\ the\ ledger
].freeze

# An application-chosen number (an ID, a timestamp, a magic constant) planted in
# index metadata. A number copied from metadata must never reach the profile:
# measured quantities are emitted, copied ones only as log2 bucket boundaries.
PLANTED_NUMBER = 1_094_929_733

def check(label, condition)
  raise "FAIL #{label}" unless condition
end

def write_json(path, data)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.generate(data))
end

def unit(type, identifier, file_path, source, metadata)
  { type: type, identifier: identifier, file_path: file_path, namespace: nil, source_code: source,
    metadata: metadata, dependencies: [], dependents: [], chunks: [] }
end

def build_index(payload)
  model = unit('model', 'Zyxwv::SecretLedgerAccount', 'app/models/zyxwv/secret_ledger_account.rb',
               "class Zyxwv::SecretLedgerAccount\n  # café\nend\n",
               table_name: 'qq_secret_ledgers', inlined_concerns: ['Hushable'],
               associations: [{ name: 'owner', type: 'belongs_to', target: 'Zyxwv::Owner' }],
               callbacks: [{ type: 'before_save', filter: 'open_sesame', origin: 'app' },
                           { type: 'after_validation', filter: '_x', origin: 'framework' }],
               validations: [{ attribute: 'iban_number' }], scopes: [],
               columns: [{ name: 'iban_number' }, { name: 'id' }])
  owner = unit('model', 'Zyxwv::Owner', 'app/models/zyxwv/owner.rb', "class Zyxwv::Owner\nend\n",
               table_name: 'qq_owners', inlined_concerns: ['Hushable'], associations: [], callbacks: [],
               validations: [], scopes: [{ name: 'open_sesame' }], column_count: PLANTED_NUMBER)
  controller = unit('controller', 'VaultController', 'app/controllers/vault_controller.rb',
                    "class VaultController\nend",
                    actions: %w[show open_sesame], filters: [{ filter: 'open_sesame', origin: 'app' }],
                    routes: { show: [{ verb: 'GET', path: '/hidden/vault/:id' }] })
  route = unit('route', 'GET /hidden/vault/:id', nil, 'GET /hidden/vault/:id', path: '/hidden/vault/:id')
  concern = unit('concern', 'Hushable', 'app/models/concerns/hushable.rb', "module Hushable\nend\n", {})
  odd = unit('quantum_widget', 'Skunkworks', 'lib/skunkworks.rb', 'x', {})
  { 'models' => [model, owner], 'controllers' => [controller], 'routes' => [route], 'concerns' => [concern],
    'skunkworks_dir' => [odd] }.each do |dir, units|
    units.each_with_index { |data, i| write_json(File.join(payload, dir, "u#{i}_0a1b2c3d.json"), data) }
    write_json(File.join(payload, dir, '_index.json'), units.map { |data| { identifier: data[:identifier] } })
  end
  write_graph(payload)
  write_manifest(payload)
end

def write_graph(payload)
  nodes = { 'Zyxwv::SecretLedgerAccount' => 'model', 'Zyxwv::Owner' => 'model', 'VaultController' => 'controller',
            'GET /hidden/vault/:id' => 'route', 'Hushable' => 'concern', 'Skunkworks' => 'quantum_widget' }
  edges = {
    'Zyxwv::SecretLedgerAccount' => [{ target: 'Zyxwv::Owner', via: 'belongs_to' },
                                     { target: 'Hushable', via: 'include' },
                                     { target: 'Skunkworks', via: 'smuggles_contraband' }],
    'Zyxwv::Owner' => [{ target: 'Zyxwv::SecretLedgerAccount', via: 'has_many' },
                       { target: 'Hushable', via: 'include' }, { target: 'NotAUnit', via: 'code_reference' }],
    'VaultController' => [{ target: 'Zyxwv::SecretLedgerAccount', via: 'code_reference' }],
    'GET /hidden/vault/:id' => [{ target: 'VaultController', via: 'route_dispatch' }],
    'Hushable' => [], 'Skunkworks' => ['VaultController']
  }
  write_json(File.join(payload, 'dependency_graph.json'),
             nodes: nodes.to_h { |id, type| [id, { type: type, file_path: 'app/secret_ledger.rb', namespace: nil }] },
             edges: edges, reverse: {}, stats: { node_count: 6 })
  write_json(File.join(payload, 'graph_analysis.json'),
             hubs: [{ identifier: 'Zyxwv::SecretLedgerAccount', dependent_count: 2 }],
             cycles: [%w[Zyxwv::SecretLedgerAccount Zyxwv::Owner]],
             stats: { cycle_count: 1, cycle_limit_reached: false, mystery_stat: 4, hub_count: 'Skunkworks',
                      orphan_count: PLANTED_NUMBER })
end

def write_manifest(payload)
  write_json(File.join(payload, 'manifest.json'),
             woods_version: '2.1.0', rails_version: '7.1.3.4', ruby_version: 'ruby-3.3.6-acme',
             git_branch: 'feature/secret-branch', git_sha: 'deadbeefcafe', root: '/home/zebediah/acme-corp',
             counts: { models: 2, controllers: 1, routes: 1, concerns: 1, skunkworks_dir: 1 }, total_units: 6,
             total_chunks: PLANTED_NUMBER, extractor_timings: { models: 0.5, skunkworks_dir: PLANTED_NUMBER / 1000.0 },
             git_enrichment: { state: 'Skunkworks' })
end

def build_app(root)
  { 'app/models/zyxwv/secret_ledger_account.rb' => "class Zyxwv::SecretLedgerAccount\n  # one\n  # two\nend\n",
    'app/models/zyxwv/owner.rb' => "class Zyxwv::Owner\nend\n",
    'app/views/vault/open_sesame.html.erb' => "<p>open_sesame</p>\n",
    'lib/skunkworks.rb' => "module Skunkworks\nend\n",
    'packs/acme-corp/app/models/thing.rb' => "class Thing\nend\n",
    'spec/models/secret_ledger_spec.rb' => "# spec\n",
    'vendor/bundle/ignored.rb' => "# ignored\n",
    'Gemfile.lock' => "GEM\n  remote: https://acme-corp.example/\n  specs:\n    acme_private_gem (1.2.3)\n" \
                      "      rack (>= 2)\n    rack (3.0.0)\n\nDEPENDENCIES\n  acme_private_gem\n" }.each do |path, text|
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end
end

def git_history(root)
  identity = ['-c', 'user.name=Zebediah Quillfeather', '-c', 'user.email=zeb@acme-corp.example',
              '-c', 'commit.gpgsign=false']
  run = ->(*args) { Open3.capture2e('git', '-C', root, *identity, *args).last.success? }
  return false unless run.call('init', '-q', '-b', 'secret-branch') && run.call('add', 'app', 'lib') &&
                      run.call('commit', '-q', '-m', 'Fix the ledger')

  File.write(File.join(root, 'app/models/zyxwv/owner.rb'), "class Zyxwv::Owner\n  # more\nend\n")
  run.call('commit', '-q', '-am', 'Fix the ledger again')
rescue SystemCallError
  false
end

def profile(*args)
  output, status = Open3.capture2(RbConfig.ruby, SCRIPT, *args)
  check('profiler exits 0', status.success?)
  output
end

# A unit file and a whole type directory inside the payload that are symlinks
# to units outside the index. Neither may be read.
def plant_escaping_links(payload, outside)
  stray = unit('model', 'Skunkworks::Stray', 'app/models/stray.rb', "class Stray\nend\n", {})
  write_json(File.join(outside, 'stray.json'), stray)
  write_json(File.join(outside, 'jobs', 'u0_0a1b2c3d.json'), unit('job', 'Skunkworks::Job', nil, 'x', {}))
  File.symlink(File.join(outside, 'stray.json'), File.join(payload, 'models', 'u9_0a1b2c3d.json'))
  File.symlink(File.join(outside, 'jobs'), File.join(payload, 'jobs'))
end

# The marker's payload must resolve inside the index: equal to it or below it
# with a separator. A sibling whose name starts with the index's name, and a
# symlink to a directory outside it, are both refused with nothing printed.
def assert_payload_contained(tmp)
  root = File.join(tmp, 'contained')
  index = File.join(root, 'tmp/woods')
  build_index(File.join(root, 'tmp/woods-old/payloads/gen-1'))
  write_json(File.join(index, 'generation.json'), number: 1, reason: 'full', payload: '../woods-old/payloads/gen-1')
  refused('a sibling-prefix payload', '--root', root)

  build_index(File.join(tmp, 'elsewhere/payloads/gen-1'))
  FileUtils.mkdir_p(File.join(index, 'payloads'))
  File.symlink(File.join(tmp, 'elsewhere/payloads/gen-1'), File.join(index, 'payloads/gen-1'))
  write_json(File.join(index, 'generation.json'), number: 1, reason: 'full', payload: 'payloads/gen-1')
  refused('a payload symlinked outside the index', '--root', root)
end

# `--compare` is total: any two JSON documents compare without raising,
# whatever sits at a metric's path on either side.
def assert_compare_total(tmp)
  sides = { 'negative' => -2, 'other_negative' => -8, 'positive' => 4, 'zero' => 0, 'null' => nil,
            'string' => '12', 'object' => { 'max' => 3 }, 'list' => [1], 'tiny' => 1.0e-308, 'huge' => 1.0e308 }
  paths = sides.to_h do |name, value|
    path = File.join(tmp, "compare-#{name}.json")
    File.write(path, JSON.generate('index' => { 'total_units' => value }, 'graph' => { 'edges_per_node' => value }))
    [name, path]
  end
  paths['missing'] = File.join(tmp, 'compare-missing.json').tap { |path| File.write(path, '{"graph":{}}') }
  paths['array'] = File.join(tmp, 'compare-array.json').tap { |path| File.write(path, '[1, 2]') }
  # Every pair in process (each would raise here); one pair through the command line.
  rows = paths.keys.product(paths.keys).to_h do |left, right|
    table = WoodsShapeProfile::Compare.call(paths[left], paths[right])
    [[left, right], table.lines.find { |line| line.start_with?('units ') }.to_s.split]
  end
  check('--compare negative positive exits 0', profile('--compare', paths['negative'], paths['positive'])
                                                 .match?(/^units\s+-2\s+4\s+-2\.00x$/))
  check('negative over positive', rows[%w[negative positive]].last(3) == %w[-2 4 -2.00x])
  check('negative over negative', rows[%w[negative other_negative]].last(3) == %w[-2 -8 4.00x])
  check('negative against zero', rows[%w[negative zero]].last == '0.00x' && rows[%w[zero negative]].last == 'inf')
  %w[null string object list missing array].each do |absent|
    check("#{absent} reads as no value", rows[['positive', absent]].last(3) == %w[4 - n/a] &&
                                          rows[[absent, 'negative']].last(3) == %w[- -2 n/a])
  end
  check('ratio overflow', rows[%w[tiny huge]].last == 'inf' && rows[%w[huge tiny]].last == '0.00x')
  output, status = Open3.capture2e(RbConfig.ruby, SCRIPT, '--compare', paths['positive'], SCRIPT)
  check('a file that is not JSON is refused cleanly', !status.success? && !output.include?('Error)'))
end

def refused(label, *args)
  output, status = Open3.capture2e(RbConfig.ruby, SCRIPT, *args)
  check("#{label} is refused", !status.success? && !output.include?('profile_version'))
  assert_no_canaries(output, label)
end

def assert_no_canaries(text, label)
  CANARIES.each { |canary| check("#{label} leaks a planted string", !text.downcase.include?(canary.downcase)) }
  check("#{label} leaks a planted number", !text.include?(PLANTED_NUMBER.to_s[0, 7]))
end

def assert_numbers(doc, with_git)
  check('profile version', doc['profile_version'] == 1)
  check('direct reader', doc.dig('index', 'reader') == 'direct')
  check('units', doc.dig('index', 'total_units') == 6)
  check('unknown type bucketed', doc.dig('index', 'units_by_type') ==
                                 { 'concern' => 1, 'controller' => 1, 'model' => 2, 'other' => 1, 'route' => 1 })
  check('multibyte source measured', doc.dig('index', 'source_lines', 'by_type', 'model', 'max') == 3)
  graph = doc['graph']
  check('edges', graph['edges'] == 9 && graph['resolved_edges'] == 8)
  check('unknown via bucketed', graph['edges_by_via']['other'] == 1 && graph['edges_by_via']['unlabelled'] == 1)
  check('hub', graph['top_hubs'].first == { 'rank' => 1, 'in_degree' => 2, 'out_degree' => 3, 'type' => 'model' })
  check('blast radius', graph.dig('top_hub_blast_radius', 'transitive_units') == 4 &&
                        graph.dig('model_blast_radius', 'structural_units', 'max') == 2)
  check('namespaces', graph.dig('namespaces', 'top_level_namespaces') == 1 &&
                      graph.dig('namespaces', 'root_units') == 4)
  check('cycle', graph.dig('cycles', 'largest_component') == 4)
  check('analysis stats filtered and bucketed', graph.dig('cycles', 'analysis') ==
                                   { 'cycle_count' => 1, 'cycle_limit_reached' => false,
                                     'orphan_count' => 2**31 })
  check('model facts', doc.dig('models', 'callbacks', 'max') == 2 &&
                       doc.dig('models', 'application_callbacks', 'max') == 1 &&
                       doc.dig('models', 'concern_fan_in_top_10') == [2])
  # The owner records only `column_count`: a count copied from metadata, not measured, so it is not used.
  check('model columns measured, not copied',
        doc.dig('models', 'columns') == { 'count' => 1, 'min' => 2, 'p50' => 2, 'p90' => 2, 'p99' => 2, 'max' => 2,
                                          'mean' => 2.0, 'histogram' => [{ 'le' => 2, 'count' => 1 }] })
  check('controller facts', doc.dig('controllers', 'actions', 'max') == 2 &&
                            doc.dig('controllers', 'routes_total_index') == 1)
  files = doc['files']
  check('files', files.dig('ruby', 'app', 'count') == 2 && files.dig('ruby', 'lib', 'count') == 1 &&
                 files.dig('ruby', 'packages', 'count') == 1 && files['view_templates'] == 1 &&
                 files['test_files'] == 1 && files.dig('ruby', 'app', 'lines', 'max') == 4)
  check('app weight', doc.dig('app_weight', 'gems_in_lockfile') == 2 &&
                      doc.dig('app_weight', 'rails_version') == '7.1.3.4' &&
                      doc.dig('app_weight', 'ruby_version').nil? &&
                      doc.dig('app_weight', 'timings') == { 'available' => false, 'reason' => 'not_requested' })
  run = doc['woods_run']
  check('run facts', run['woods_version'] == '2.1.0' && run['extraction_mode'] == 'incremental' &&
                     run['units_by_directory']['other'] == 1 && run['git_enrichment_state'] == 'other')
  # Everything in woods_run is copied from the manifest, so it is emitted only as a log2 bucket boundary.
  check('run facts bucketed', run['extractor_timings'] == { 'models' => 0.5, 'other' => 2.0**21 } &&
                              run['total_units'] == 8 && run['total_chunks'] == 2**31 && run['generation'] == 4 &&
                              run['units_by_directory'] == { 'concerns' => 1, 'controllers' => 1, 'models' => 2,
                                                             'other' => 1, 'routes' => 1 } &&
                              run['extractor_timings_total'] == 2.0**21)
  assert_history(doc['history'], with_git)
end

def assert_history(history, with_git)
  if with_git
    check('history', history['available'] == true && history['total_commits'] == 2 &&
                     history['contributors'] == 1 && history.dig('files_per_commit', 'max') == 4 &&
                     history.dig('commits_per_app_file', 'max') == 2)
  else
    check('history honest without git', history['available'] == false)
  end
end

def expect_leak(label)
  yield
rescue WoodsShapeProfile::Privacy::Leak
  nil
else
  raise "FAIL self-check accepted #{label}"
end

def assert_self_check(doc)
  privacy = WoodsShapeProfile::Privacy
  check('clean profile passes the self-check', privacy.verify!(doc))
  mutate = lambda do |&change|
    JSON.parse(JSON.generate(doc)).tap(&change)
  end
  expect_leak('a string value') { privacy.verify!(mutate.call { |d| d['index']['reader'] = 'Zyxwv::Owner' }) }
  expect_leak('a key') { privacy.verify!(mutate.call { |d| d['graph']['edges_by_via']['smuggles_contraband'] = 1 }) }
  expect_leak('a nested string') { privacy.verify!(mutate.call { |d| d['graph']['top_hubs'] << ['Hushable'] }) }
  expect_leak('a bad version') { privacy.verify!(mutate.call { |d| d['woods_run']['woods_version'] = 'acme 1.0' }) }
  expect_leak('a version elsewhere') { privacy.verify!(mutate.call { |d| d['index']['reader'] = '2.1.0' }) }
  assert_numeric_rule(privacy, mutate)
  assert_seal_aborts(doc)
end

# Numbers: only under a measured-quantity key or in a count table, never negative,
# and only bucket boundaries where the value was copied from index metadata.
def assert_numeric_rule(privacy, mutate)
  expect_leak('a number under a non-numeric key') do
    privacy.verify!(mutate.call { |d| d['graph']['available'] = PLANTED_NUMBER })
  end
  expect_leak('a number in place of a reason') do
    privacy.verify!(mutate.call { |d| d['app_weight']['timings']['reason'] = PLANTED_NUMBER })
  end
  expect_leak('a negative count') { privacy.verify!(mutate.call { |d| d['index']['total_units'] = -3 }) }
  expect_leak('a copied run fact') { privacy.verify!(mutate.call { |d| d['woods_run']['total_units'] = 6 }) }
  expect_leak('a copied timing') do
    privacy.verify!(mutate.call { |d| d['woods_run']['extractor_timings']['models'] = 0.3 })
  end
  expect_leak('a copied analysis count') do
    privacy.verify!(mutate.call { |d| d['graph']['cycles']['analysis']['cycle_count'] = 3 })
  end
  check('a measured extreme passes', privacy.verify!(mutate.call { |d| d['index']['total_units'] = PLANTED_NUMBER }))
end

# Privacy.seal is what main prints through: a leak must exit non-zero and say nothing of the value.
def assert_seal_aborts(doc)
  stderr = $stderr
  $stderr = StringIO.new
  begin
    WoodsShapeProfile::Privacy.seal(doc.merge('index' => doc['index'].merge('reader' => 'Zyxwv::Owner')))
  rescue SystemExit => e
    message = $stderr.string
    check('seal exits non-zero', !e.success?)
    check('abort message hides the value', message.include?('self-check failed') && !message.include?('Zyxwv'))
  else
    raise 'FAIL seal printed a leaking profile'
  ensure
    $stderr = stderr
  end
end

Dir.mktmpdir('woods-shape-profile') do |tmp|
  root = File.join(tmp, 'acme-corp')
  index = File.join(root, 'tmp/woods')
  build_app(root)
  build_index(File.join(index, 'payloads/gen-3'))
  write_json(File.join(index, 'generation.json'), number: 3, reason: 'incremental', payload: 'payloads/gen-3')
  plant_escaping_links(File.join(index, 'payloads/gen-3'), File.join(tmp, 'outside'))
  with_git = git_history(root)

  text = profile('--root', root)
  assert_no_canaries(text, 'the profile')
  doc = JSON.parse(text)
  assert_numbers(doc, with_git)
  assert_self_check(doc)

  # A flat (pre-generation) index, named explicitly, written with --out.
  out = File.join(tmp, 'flat.json')
  check('--out prints nothing', profile('--root', root, File.join(index, 'payloads/gen-3'), '--out', out).empty?)
  flat = JSON.parse(File.read(out))
  check('flat index', flat.dig('index', 'total_units') == 6 && flat.dig('woods_run', 'extraction_mode') == 'unknown')

  assert_payload_contained(tmp)

  table = profile('--compare', out, out)
  assert_no_canaries(table, 'the comparison')
  check('comparison table', table.lines.size > 10 && table.match?(/^units\s+6\s+6\s+1\.00x$/))

  # The ratio is B / A in both directions, zero included.
  empty = File.join(tmp, 'empty.json')
  File.write(empty, JSON.generate(flat.merge('index' => flat.fetch('index').merge('total_units' => 0))))
  check('zero A reads as unbounded', profile('--compare', empty, out).match?(/^units\s+0\s+6\s+inf$/))
  check('zero B reads as none of A', profile('--compare', out, empty).match?(/^units\s+6\s+0\s+0\.00x$/))
  check('zero against zero is equal', profile('--compare', empty, empty).match?(/^units\s+0\s+0\s+1\.00x$/))
  check('a zero side sorts first', profile('--compare', out, empty).lines[1].start_with?('units'))

  assert_compare_total(tmp)

  puts "PASS shape profile: no planted string emitted, numbers exact, self-check aborts on a bypass#{
    ' (git history skipped: git unavailable)' unless with_git}"
end
