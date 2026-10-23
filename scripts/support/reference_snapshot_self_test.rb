# frozen_string_literal: true

# Run with Woods available on the load path; no Rails, Docker or app database.
require 'tmpdir'
require 'fileutils'
require_relative 'reference_snapshot'
require_relative 'reference_contract'

def assert(message)
  raise message unless yield
  puts "PASS #{message}"
end

def rejected?
  yield
  false
rescue RuntimeError, KeyError
  true
end

span_corruptions = {
  'target type' => ->(spans) { spans.first['target_type'] = 'concern' },
  'target identity' => ->(spans) { spans.first['target'] = 'WrongTarget' },
  'file-relative line' => ->(spans) { spans.first['line'] -= 5 },
  'column' => ->(spans) { spans.first['column'] += 1 },
  'length' => ->(spans) { spans.first['length'] -= 1 },
  'coordinate type' => ->(spans) { spans.first['line'] = spans.first['line'].to_s },
  'kind' => ->(spans) { spans.first['kind'] = 'constant_read' },
  'confidence' => ->(spans) { spans.first['confidence'] = 'static' },
  'missing span' => ->(spans) { spans.clear },
  'extra span' => ->(spans) { spans << spans.first.dup }
}

Dir.mktmpdir('reference-oracle-self-test') do |root|
  Dir.chdir(root) do
    FileUtils.mkdir_p('app/models')
    File.write('app/models/reference.rb', "class Reference; end\n")
    %w[left right].each do |index|
      FileUtils.mkdir_p("#{index}/poros")
      key = Woods::SourceInputs::PrivateKey.new(output_dir: index, create: true)
      identity = OpenSSL::HMAC.hexdigest('SHA256', key.bytes, File.binread('app/models/reference.rb'))
      File.write("#{index}/source_references.json", JSON.generate(
        'version' => 1, 'files' => { 'app/models/reference.rb' => { 'identity' => identity, 'analysis' => {} } }, 'owners' => []
      ))
      File.write("#{index}/poros/reference.json", JSON.generate(
        'type' => 'poro', 'identifier' => 'Reference', 'extracted_at' => index,
        'source_code' => "class Reference\n    ReferenceTarget.generate\nend\n",
        'metadata' => { 'important' => true, 'references' => [ReferenceContract.constant('poro', 'ReferenceTarget', 2)] },
        'dependencies' => [],
        'dependents' => [{ 'type' => 'poro', 'identifier' => 'A' }, { 'type' => 'poro', 'identifier' => 'B' }]
      ))
      File.write("#{index}/poros/_index.json", JSON.generate([{ 'identifier' => 'Reference' }, { 'identifier' => 'ReferenceTwo' }]))
      File.write("#{index}/dependency_graph.json", JSON.generate(
        'edges' => { 'Reference' => [] }, 'reverse_via' => {}, 'pagerank' => { 'Reference' => 0.123456701 }
      ))
    end
    assert('independent verified HMAC keys and extraction timestamps compare equal') do
      ReferenceSnapshot.differences('left', 'right', semantic: false).empty?
    end
    path = 'right/poros/reference.json'
    original = File.read(path)
    span_corruptions.each do |name, corrupt|
      unit = JSON.parse(original)
      corrupt.call(unit.fetch('metadata').fetch('references'))
      File.write(path, JSON.generate(unit))
      assert("#{name} corruption fails both strict and semantic snapshot equivalence") do
        [true, false].all? do |semantic|
          !ReferenceSnapshot.differences('left', 'right', semantic: semantic).empty?
        end
      end
    end
    File.write(path, original)
    unit = JSON.parse(original)
    fingerprint = ReferenceSnapshot.fingerprint('right')
    unit['extracted_at'] = 'tampered timestamp'
    File.write(path, JSON.generate(unit))
    assert('failure-isolation fingerprints detect even normalized timestamps') do
      ReferenceSnapshot.fingerprint('right') != fingerprint
    end
    File.write(path, original)
    File.write('right/unexpected', 'extra')
    assert('failure-isolation fingerprints detect added payload files') do
      ReferenceSnapshot.fingerprint('right') != fingerprint
    end
    File.unlink('right/unexpected')
    unit = JSON.parse(original)
    unit['dependents'].reverse!
    File.write(path, JSON.generate(unit))
    assert('dependent order is reported strictly and tolerated semantically') do
      ReferenceSnapshot.differences('left', 'right').empty? &&
        !ReferenceSnapshot.differences('left', 'right', semantic: false).empty?
    end
    unit['metadata']['important'] = false
    File.write(path, JSON.generate(unit))
    assert('meaningful unit content still fails semantic equivalence') do
      !ReferenceSnapshot.differences('left', 'right').empty?
    end
    File.write(path, original)
    index_path = 'right/poros/_index.json'
    File.write(index_path, JSON.generate(JSON.parse(File.read(index_path)).reverse))
    assert('type index ordering is reported strictly and tolerated semantically') do
      ReferenceSnapshot.differences('left', 'right').empty? &&
        ReferenceSnapshot.differences('left', 'right', semantic: false).any? { |entry| entry[:path].start_with?('indexes/') }
    end
    graph_path = 'right/dependency_graph.json'
    graph = JSON.parse(File.read(graph_path))
    graph['reverse_via'] = { 'WrongTarget' => [{ 'source' => 'Reference', 'source_type' => 'poro', 'via' => 'code_reference' }] }
    File.write(graph_path, JSON.generate(graph))
    assert('incorrect reverse relationships fail equivalence') do
      ReferenceSnapshot.differences('left', 'right').any? { |entry| entry[:path] == 'graph/reverse_via' }
    end
    cache_path = 'right/source_references.json'
    cache = JSON.parse(File.read(cache_path))
    cache['files']['app/models/reference.rb']['identity'] = '0' * 64
    File.write(cache_path, JSON.generate(cache))
    assert('unverified HMACs fail before normalization') do
      begin
        ReferenceSnapshot.read('right')
        false
      rescue RuntimeError => error
        error.message.include?('cache source identity mismatch')
      end
    end
  end
end

# Five PORO annotation lines precede the unchanged public arrival fixture.
source = "# annotation\n" * 5 + File.read(File.expand_path('../fixtures/source_references/app/models/reference_arrival_caller.rb', __dir__))
before = { 'type' => 'poro', 'identifier' => 'ReferenceArrivalCaller', 'source_code' => source,
           'extracted_at' => 'retained timestamp', 'dependencies' => [], 'chunks' => [{ 'source_code' => 'retained chunk' }],
           'metadata' => { 'references' => [], 'git' => { 'sha' => 'retained' }, 'unrelated' => true } }
saved = Marshal.load(Marshal.dump(before))
arrival = ReferenceContract.arrival(before, spans: true)
expected_spans = [{ 'line' => 8, 'column' => 4, 'length' => 20, 'target' => 'ReferenceLaterTarget',
                    'target_type' => 'poro', 'kind' => 'constant', 'confidence' => 'verified' }]
assert('arrival admits exactly the labelled typed span without mutating the baseline') do
  before == saved && arrival.fetch('metadata').fetch('references') == expected_spans &&
    arrival.fetch('dependencies') == [{ 'type' => 'poro', 'target' => 'ReferenceLaterTarget', 'via' => 'code_reference' }]
end
span_corruptions.each do |name, corrupt|
  actual = Marshal.load(Marshal.dump(arrival))
  corrupt.call(actual.fetch('metadata').fetch('references'))
  assert("#{name} corruption fails the expected arrival delta and independent span oracle") do
    rejected? { ReferenceContract.assert_payload!(actual, arrival) } &&
      rejected? { ReferenceContract.assert_references!(actual, expected_spans) }
  end
end
[nil, expected_spans].each do |invalid|
  actual = Marshal.load(Marshal.dump(before))
  actual.fetch('metadata')['references'] = invalid
  assert('initial unresolved state requires an explicit empty array') do
    rejected? { ReferenceContract.arrival(actual, spans: true) }
  end
end
legacy = Marshal.load(Marshal.dump(before))
legacy.fetch('metadata').delete('references')
assert('missing span field is rejected in span mode and preserved in dependencies-only mode') do
  rejected? { ReferenceContract.arrival(legacy, spans: true) } &&
    ReferenceContract.arrival(legacy, spans: false).fetch('metadata') == legacy.fetch('metadata')
end
assert('integer coordinates remain required even when numeric equality would accept a float') do
  actual = Marshal.load(Marshal.dump(arrival))
  actual.fetch('metadata').fetch('references').first['line'] = 8.0
  rejected? { ReferenceContract.assert_references!(actual, expected_spans) } &&
    rejected? { ReferenceContract.assert_payload!(actual, arrival) }
end
assert('initial unresolved caller cannot already carry dependencies') do
  rejected? { ReferenceContract.arrival(before.merge('dependencies' => arrival.fetch('dependencies')), spans: true) }
end
%w[source_code extracted_at chunks metadata].each do |field|
  [arrival, before].each do |expected|
    actual = Marshal.load(Marshal.dump(expected))
    actual[field] = 'corrupt'
    assert("arrival/deletion preserve #{field} exactly") do
      rejected? { ReferenceContract.assert_payload!(actual, expected) }
    end
  end
end
assert('deletion requires original dependencies and complete span withdrawal') do
  stale_span = Marshal.load(Marshal.dump(before))
  stale_span.fetch('metadata')['references'] = expected_spans
  stale_edge = before.merge('dependencies' => arrival.fetch('dependencies'))
  ReferenceContract.assert_payload!(Marshal.load(Marshal.dump(before)), before)
  rejected? { ReferenceContract.assert_payload!(stale_span, before) } &&
    rejected? { ReferenceContract.assert_payload!(stale_edge, before) }
end
unicode = { 'identifier' => 'Synthetic', 'source_code' => "# é\né; ReferenceLaterTarget\n",
            'metadata' => { 'references' => [ReferenceContract.constant('poro', 'ReferenceLaterTarget', 2)] } }
assert('span slices use UTF-8 byte offsets, including preceding annotated lines') do
  ReferenceContract.assert_references!(unicode, unicode.fetch('metadata').fetch('references'))
  unicode.fetch('metadata').fetch('references').first['column'] = 3
  rejected? { ReferenceContract.assert_references!(unicode, unicode.fetch('metadata').fetch('references')) }
end
