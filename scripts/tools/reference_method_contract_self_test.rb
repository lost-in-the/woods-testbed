# frozen_string_literal: true

# Independent metadata oracle only: no producer, Rails, cache loader or Docker.
require_relative '../support/reference_contract'

def unit_with_method(value)
  { 'identifier' => 'Synthetic', 'source_code' => "    ReferenceTarget\n",
    'metadata' => { 'references' => [ReferenceContract.constant('poro', 'ReferenceTarget', 1).merge('method' => value)] } }
end

def rejects_method!(value, after_valid: false)
  unit = unit_with_method(value)
  if after_valid
    unit['source_code'] *= 2
    unit.fetch('metadata').fetch('references').first['line'] = 2
    unit.fetch('metadata').fetch('references').unshift(ReferenceContract.constant('poro', 'ReferenceTarget', 1).merge('method' => 'valid'))
  end
  begin
    ReferenceContract.assert_references!(unit, unit.fetch('metadata').fetch('references'))
  rescue RuntimeError
    return
  end
  raise "invalid selector accepted even when expectations agree: #{value.inspect[0, 100]}"
end

rejects_method!('')
puts 'PASS empty selector fails independently of expected/actual equality'

[nil, 1, false, [], {}, 'a' * 4097, 'é' * 2049, "x\x00", "x\n", "x\x7f", "x\u0085",
 "\xff".b].each do |value|
  rejects_method!(value)
  rejects_method!(value, after_valid: true)
end
puts 'PASS malformed present selectors reject type, UTF-8, byte-limit and control-character violations'

['a', 'a' * 4096, 'é' * 2048, 'café', 'ready?', 'save!', 'value=', '[]', '[]=', '-@', '+'].each do |value|
  unit = unit_with_method(value)
  ReferenceContract.assert_references!(unit, unit.fetch('metadata').fetch('references'))
end
puts 'PASS 1..4096 UTF-8 bytes, punctuation, operators and Unicode remain valid'

source = ("# annotation\n" * 5) + ReferenceContract.selector_bounds_source
unit = { 'identifier' => 'ReferenceSelectorBounds', 'source_code' => source,
         'metadata' => { 'references' => ReferenceContract.selector_bounds_spans } }
ReferenceContract.assert_references!(unit, ReferenceContract.selector_bounds_spans)
sizes = unit.fetch('metadata').fetch('references').map(&:size)
raise "wrong boundary key shapes: #{sizes}" unless sizes == [8, 7, 8, 7]
raise 'expanded public fixture retained placeholders' if source.include?('__ASCII_') || source.include?('__UNICODE_')
RubyVM::InstructionSequence.compile(source)
puts 'PASS boundary fixture parses without execution; oversized ASCII/Unicode selectors keep exact seven-key constants'

expected = ReferenceContract.selector_bounds_spans
expected.each_index do |index|
  corrupt = Marshal.load(Marshal.dump(expected))
  if index.even?
    corrupt[index].delete('method')
  else
    corrupt[index]['method'] = index == 1 ? 'a' * 4097 : 'é' * 2049
  end
  actual = unit.merge('metadata' => { 'references' => corrupt })
  begin
    ReferenceContract.assert_references!(actual, expected)
  rescue RuntimeError
    next
  end
  raise "boundary selector presence corruption accepted at #{index}"
end
puts 'PASS both missing boundary annotations and present oversized annotations fail the exact oracle'
