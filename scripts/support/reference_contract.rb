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
      if span.key?('method')
        selector = span.fetch('method')
        utf8 = selector.is_a?(String) ? selector.dup.force_encoding(Encoding::UTF_8) : nil
        valid = utf8 && utf8.valid_encoding? && (1..4096).cover?(utf8.bytesize) && !utf8.match?(/[[:cntrl:]]/)
        raise 'invalid present method selector' unless valid
      end
      offset = source.lines.take(span.fetch('line') - 1).sum(&:bytesize) + span.fetch('column')
      bytes = source.byteslice(offset, span.fetch('length'))
      raise "span does not cover its constant: #{span.inspect}" unless bytes == span.fetch('target')
    end
  end

  def arrival(before, spans:, methods: false)
    raise 'method annotations require constant spans' if methods && !spans

    raise 'arrival caller was already resolved' unless before.fetch('dependencies') == []

    assert_references!(before, []) if spans
    expected = Marshal.load(Marshal.dump(before))
    expected['dependencies'] = [{ 'type' => 'poro', 'target' => 'ReferenceLaterTarget', 'via' => 'code_reference' }]
    if spans
      # PORO's five annotation lines + fixture line 3; not file coordinates.
      expected.fetch('metadata')['references'] = [constant('poro', 'ReferenceLaterTarget', 8)]
      expected.fetch('metadata').fetch('references').first['method'] = 'generate' if methods
      assert_references!(expected, expected.fetch('metadata').fetch('references'))
    end
    expected
  end

  # Fixture file lines 3..28 and 38..60 plus PORO's five annotation lines. These labels
  # come from the public source, never from a producer snapshot or AST.
  def method_caller_spans(selector: 'generate')
    [constant('poro', 'ReferenceTarget', 8).merge('method' => selector),
     constant('poro', 'ReferenceTarget', 9, 12),
     constant('poro', 'ReferenceTarget', 10, 12),
     constant('poro', 'ReferenceTarget', 11).merge('method' => 'generate'),
     constant('poro', 'ReferenceAlternateTarget', 11, 29),
     constant('poro', 'ReferenceTarget', 12).merge('method' => 'new'),
     constant('poro', 'ReferenceTarget', 13).merge('method' => 'send'),
     constant('poro', 'ReferenceTarget', 14),
     constant('poro', 'ReferenceTarget', 15),
     constant('poro', 'ReferenceTarget', 16).merge('method' => 'missing_selector'),
     constant('poro', 'ReferenceTarget', 17, 5).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 18, 6).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 19).merge('method' => 'call'),
     constant('poro', 'ReferenceTarget', 20).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 21).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 22).merge('method' => 'value='),
     constant('poro', 'ReferenceTarget', 23).merge('method' => '[]'),
     constant('poro', 'ReferenceTarget', 24).merge('method' => '[]='),
     constant('poro', 'ReferenceTarget', 25, 12).merge('method' => '-@'),
     constant('poro', 'ReferenceTarget', 26, 13),
     constant('poro', 'ReferenceAlternateTarget', 26, 30),
     constant('poro', 'ReferenceTarget', 27).merge('method' => 'generate'),
     constant('poro', 'ReferenceAlternateTarget', 27, 29).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 28).merge('method' => 'generate'),
     constant('poro', 'ReferenceAlternateTarget', 28, 31).merge('method' => 'generate'),
     constant('poro', 'ReferenceSpace::ReferenceTarget', 29).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 30).merge('method' => 'ready?'),
     constant('poro', 'ReferenceTarget', 31).merge('method' => 'save!'),
     constant('poro', 'ReferenceTarget', 32).merge('method' => 'café'),
     constant('poro', 'ReferenceTarget', 33).merge('method' => '+'),
     constant('poro', 'ReferenceTarget', 43, 14),
     constant('poro', 'ReferenceTarget', 48, 14),
     constant('poro', 'ReferenceAlternateTarget', 48, 30).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 53, 14).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 56, 8),
     constant('poro', 'ReferenceTarget', 59, 8),
     constant('poro', 'ReferenceAlternateTarget', 59, 24).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 62, 8).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 65, 9),
     constant('poro', 'ReferenceAlternateTarget', 65, 33),
     constant('poro', 'ReferenceTarget', 65, 58).merge('method' => 'generate'),
     constant('poro', 'ReferenceTarget', 65, 85).merge('method' => 'generate')]
  end

  # Deterministic expansion of a synthetic public source template. Labels below
  # are fixed by file lines/byte lengths, independently of producer output.
  def selector_bounds_source
    File.read(File.expand_path('../fixtures/method_references/reference_selector_bounds.rb', __dir__))
      .sub('__ASCII_4096__', 'a' * 4096).sub('__ASCII_4097__', 'a' * 4097)
      .sub('__UNICODE_4096__', 'é' * 2048).sub('__UNICODE_4098__', 'é' * 2049)
  end

  def selector_bounds_spans
    [constant('poro', 'ReferenceTarget', 8).merge('method' => 'a' * 4096),
     constant('poro', 'ReferenceTarget', 9),
     constant('poro', 'ReferenceTarget', 10).merge('method' => 'é' * 2048),
     constant('poro', 'ReferenceTarget', 11)]
  end

  # This is a real caller edit: source, chunks, timestamps and cache identities
  # may change normally. Metadata-only arrival/deletion uses assert_payload!.
  def assert_selector_edit!(before, after)
    %w[type identifier dependencies].each do |field|
      raise "selector edit changed #{field}" unless before.fetch(field).eql?(after.fetch(field))
    end
    source = before.fetch('source_code')
    edited = source.sub('ReferenceTarget.generate', 'ReferenceTarget.dispatch')
    raise 'selector edit changed unexpected source bytes' unless edited != source && edited.bytesize == source.bytesize && after.fetch('source_code') == edited

    expected = Marshal.load(Marshal.dump(before.fetch('metadata').fetch('references')))
    expected.first['method'] = 'dispatch'
    assert_references!(after, expected)
  end

  # Compare the whole lookup, including timestamps, source, chunks and Git facts.
  def assert_payload!(actual, expected)
    raise 'reference delta changed unexpected caller fields' unless actual.eql?(expected)
  end
end
