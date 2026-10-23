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

method_corruptions = {
  'missing method' => ->(spans) { spans.first.delete('method') },
  'wrong method' => ->(spans) { spans.first['method'] = 'new' },
  'same-length selector replacement' => ->(spans) { spans.first['method'] = 'dispatch' },
  'extra method on bare constant' => ->(spans) { spans[1]['method'] = 'generate' },
  'method on argument constant' => ->(spans) { spans[4]['method'] = 'generate' },
  'method on same-target argument' => ->(spans) { spans[2]['method'] = 'generate' },
  'duplicate receiver' => ->(spans) { spans.insert(1, spans.first.dup) },
  'widened receiver span' => ->(spans) { spans.first['length'] += '.generate'.bytesize },
  'null method' => ->(spans) { spans.first['method'] = nil },
  'empty method' => ->(spans) { spans.first['method'] = '' },
  'extra unknown key' => ->(spans) { spans.first['unknown'] = true },
  'terminal chain selector' => ->(spans) { spans[5]['method'] = 'call' },
  'send argument selector' => ->(spans) { spans[6]['method'] = 'generate' },
  'compound attribute write method' => ->(spans) { spans[7]['method'] = 'value' },
  'compound index write method' => ->(spans) { spans[8]['method'] = '[]' },
  'implicit call selector' => ->(spans) { spans[12]['method'] = 'generate' },
  'setter missing equals' => ->(spans) { spans[15]['method'] = 'value' },
  'index reader mistaken for writer' => ->(spans) { spans[16]['method'] = '[]=' },
  'index writer missing equals' => ->(spans) { spans[17]['method'] = '[]' },
  'unary selector missing at sign' => ->(spans) { spans[18]['method'] = '-' },
  'multi-expression group first constant annotated' => ->(spans) { spans[19]['method'] = 'generate' },
  'multi-expression group final constant annotated' => ->(spans) { spans[20]['method'] = 'generate' },
  'nested argument method missing' => ->(spans) { spans[22].delete('method') },
  'block inner method replaced' => ->(spans) { spans[24]['method'] = 'new' },
  'qualified occurrence narrowed' => ->(spans) { spans[25]['length'] = 'ReferenceTarget'.bytesize },
  'Unicode selector changed' => ->(spans) { spans[28]['method'] = 'cafe' },
  'operator selector missing' => ->(spans) { spans[29].delete('method') },
  'control character selector' => ->(spans) { spans.first['method'] = "generate\n" },
  '4097-byte selector' => ->(spans) { spans.first['method'] = 'a' * 4097 },
  '4098-byte Unicode selector' => ->(spans) { spans.first['method'] = 'é' * 2049 },
  'rescue attribute target setter' => ->(spans) { spans.fetch(30)['method'] = 'value=' },
  'rescue index target setter' => ->(spans) { spans.fetch(31)['method'] = '[]=' },
  'for attribute target setter' => ->(spans) { spans.fetch(34)['method'] = 'value=' },
  'for index target setter' => ->(spans) { spans.fetch(35)['method'] = '[]=' },
  'nested for attribute target setter' => ->(spans) { spans.fetch(38)['method'] = 'value=' },
  'nested for index target setter' => ->(spans) { spans.fetch(39)['method'] = '[]=' },
  'rescue nested index call omitted' => ->(spans) { spans.fetch(32).delete('method') },
  'rescue nested receiver call omitted' => ->(spans) { spans.fetch(33).delete('method') },
  'for nested index call omitted' => ->(spans) { spans.fetch(36).delete('method') },
  'for nested receiver call omitted' => ->(spans) { spans.fetch(37).delete('method') },
  'destructured index call omitted' => ->(spans) { spans.fetch(40).delete('method') },
  'destructured receiver call omitted' => ->(spans) { spans.fetch(41).delete('method') }
}
arrival_method_corruptions = method_corruptions.slice(
  'missing method', 'wrong method', 'same-length selector replacement', 'duplicate receiver',
  'widened receiver span', 'null method', 'empty method', 'extra unknown key',
  'control character selector', '4097-byte selector', '4098-byte Unicode selector'
)
method_source = ("# annotation\n" * 5) + File.read(File.expand_path('../fixtures/method_references/reference_method_caller.rb', __dir__))
method_unit = { 'type' => 'poro', 'identifier' => 'ReferenceMethodCaller', 'source_code' => method_source,
                'dependencies' => [], 'metadata' => { 'references' => ReferenceContract.method_caller_spans } }
assert('hand-labelled mixed seven/eight-key spans slice the public fixture exactly') do
  ReferenceContract.assert_references!(method_unit, ReferenceContract.method_caller_spans)
  method_unit.fetch('metadata').fetch('references').map(&:size).uniq.sort == [7, 8]
end
assert('rescue/for targets omit methods while their nested receiver/index calls retain selectors') do
  slots = ReferenceContract.method_caller_spans.select { |span| span.fetch('line') >= 43 }
  slots.map(&:size) == [7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8]
end
method_corruptions.each do |name, corrupt|
  actual = Marshal.load(Marshal.dump(method_unit))
  corrupt.call(actual.fetch('metadata').fetch('references'))
  assert("#{name} fails the independent method span oracle") do
    rejected? { ReferenceContract.assert_references!(actual, ReferenceContract.method_caller_spans) }
  end
end

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
        'source_code' => method_source,
        'metadata' => { 'important' => true, 'references' => ReferenceContract.method_caller_spans },
        'dependencies' => [],
        'dependents' => [{ 'type' => 'poro', 'identifier' => 'A' }, { 'type' => 'poro', 'identifier' => 'B' }]
      ))
      File.write("#{index}/poros/reference_bounds.json", JSON.generate(
        'type' => 'poro', 'identifier' => 'ReferenceSelectorBounds',
        'source_code' => ("# annotation\n" * 5) + ReferenceContract.selector_bounds_source,
        'metadata' => { 'references' => ReferenceContract.selector_bounds_spans }, 'dependencies' => []
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
    span_corruptions.merge(method_corruptions).each do |name, corrupt|
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
    bounds_path = 'right/poros/reference_bounds.json'
    bounds_original = File.read(bounds_path)
    4.times do |index|
      unit = JSON.parse(bounds_original)
      span = unit.fetch('metadata').fetch('references').fetch(index)
      if index.even?
        span.delete('method')
      else
        span['method'] = index == 1 ? 'a' * 4097 : 'é' * 2049
      end
      File.write(bounds_path, JSON.generate(unit))
      assert("boundary selector presence corruption #{index} fails strict and semantic snapshots") do
        [true, false].all? do |semantic|
          !ReferenceSnapshot.differences('left', 'right', semantic: semantic).empty?
        end
      end
    end
    File.write(bounds_path, bounds_original)
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

method_arrival = ReferenceContract.arrival(before, spans: true, methods: true)
assert('method mode arrival adds exactly one eight-key receiver and preserves the whole caller') do
  expected = Marshal.load(Marshal.dump(arrival))
  expected.fetch('metadata').fetch('references').first['method'] = 'generate'
  method_arrival.eql?(expected) && before.eql?(saved)
end

arrival_method_corruptions.each do |name, corrupt|
  # Arrival has one receiver; the mixed-fixture set also runs both snapshots.
  actual = Marshal.load(Marshal.dump(method_arrival))
  corrupt.call(actual.fetch('metadata').fetch('references'))
  assert("#{name} fails method-mode whole-payload arrival preservation") do
    rejected? { ReferenceContract.assert_payload!(actual, method_arrival) }
  end
end
%w[source_code extracted_at chunks metadata].each do |field|
  actual = Marshal.load(Marshal.dump(method_arrival))
  actual[field] = 'corrupt'
  assert("method arrival preserves unrelated #{field} exactly") do
    rejected? { ReferenceContract.assert_payload!(actual, method_arrival) }
  end
end
assert('method deletion requires complete original payload restoration') do
  rejected? { ReferenceContract.assert_payload!(method_arrival, before) }
end
%w[git unrelated].each do |field|
  [method_arrival, before].each do |expected|
    actual = Marshal.load(Marshal.dump(expected))
    actual.fetch('metadata')[field] = 'changed bytes'
    assert("method arrival/deletion preserve unrelated metadata #{field}") do
      rejected? { ReferenceContract.assert_payload!(actual, expected) }
    end
  end
end
assert('method metadata-only rewrites reject unknown payload fields') do
  actual = Marshal.load(Marshal.dump(method_arrival))
  actual['unexpected'] = 'cannot be normalized away'
  rejected? { ReferenceContract.assert_payload!(actual, method_arrival) }
end
edited = Marshal.load(Marshal.dump(method_unit))
edited['source_code'] = method_source.sub('ReferenceTarget.generate', 'ReferenceTarget.dispatch')
edited.fetch('metadata')['references'] = ReferenceContract.method_caller_spans(selector: 'dispatch')
edited['extracted_at'] = 'normal edit timestamp'
edited['chunks'] = ['normal edited chunks']
assert('same-length source edit changes only the labelled selector and allows normal extraction fields') do
  ReferenceContract.assert_selector_edit!(method_unit, edited)
  true
end
%w[dependencies source_code references].each do |field|
  actual = Marshal.load(Marshal.dump(edited))
  case field
  when 'dependencies' then actual['dependencies'] = [{ 'target' => 'WrongTarget' }]
  when 'source_code' then actual['source_code'] += ' '
  when 'references' then actual.fetch('metadata').fetch('references').first['column'] += 1
  end
  assert("selector-only edit rejects changed #{field}") do
    rejected? { ReferenceContract.assert_selector_edit!(method_unit, actual) }
  end
end
