# frozen_string_literal: true

# Hand-labelled expectations for the bounded verified-constant producer.
# Keep these independent of Woods' parser/projector and snapshot normalization.
module ReferenceContract
  module_function

  # Published source: 1-based lines, 0-based UTF-8 byte columns/lengths.
  def constant(type, target, line, column = 4)
    { 'line' => line, 'column' => column, 'length' => target.bytesize,
      'target' => target, 'target_type' => type, 'kind' => 'constant', 'confidence' => 'verified' }
  end

  def assert_references!(unit, expected)
    actual = unit.fetch('metadata').fetch('references')
    raise "wrong verified spans for #{unit.fetch('identifier')}: #{actual.inspect}" unless actual.eql?(expected)

    source = unit.fetch('source_code')
    expected.each do |span|
      offset = source.lines.take(span.fetch('line') - 1).sum(&:bytesize) + span.fetch('column')
      bytes = source.byteslice(offset, span.fetch('length'))
      raise "span does not cover its constant: #{span.inspect}" unless bytes == span.fetch('target')
    end
  end

  def arrival(before, spans:)
    raise 'arrival caller was already resolved' unless before.fetch('dependencies') == []

    assert_references!(before, []) if spans
    expected = Marshal.load(Marshal.dump(before))
    expected['dependencies'] = [{ 'type' => 'poro', 'target' => 'ReferenceLaterTarget', 'via' => 'code_reference' }]
    if spans
      # PORO's five annotation lines + fixture line 3; not file coordinates.
      expected.fetch('metadata')['references'] = [constant('poro', 'ReferenceLaterTarget', 8)]
      assert_references!(expected, expected.fetch('metadata').fetch('references'))
    end
    expected
  end

  # Compare the whole lookup, including timestamps, source, chunks and Git facts.
  def assert_payload!(actual, expected)
    raise 'reference delta changed unexpected caller fields' unless actual.eql?(expected)
  end
end
