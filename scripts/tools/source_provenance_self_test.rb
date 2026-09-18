# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative '../support/source_provenance'

def rejected
  yield
rescue RuntimeError, KeyError
  return
else
  raise 'invalid provenance was accepted'
end

Dir.mktmpdir('source-provenance-oracle') do |root|
  relative = 'app/services/pay.rb'
  FileUtils.mkdir_p(File.join(root, 'app/services'))
  File.binwrite(File.join(root, relative), 'after')
  outputs = %w[first second].map do |name|
    output = File.join(root, name)
    payload = File.join(output, 'payloads/gen-1')
    FileUtils.mkdir_p(payload)
    key = Random.bytes(32)
    File.binwrite(File.join(output, '.source-inputs.key'), key, perm: 0o600)
    File.write(File.join(output, 'generation.json'), JSON.generate(number: 1, payload: 'payloads/gen-1'))
    data = { version: 1, generation: 1, root: root, key_id: Digest::SHA256.hexdigest(key),
             rules: 'a' * 64, boot_verified: false, complete: true, errors: [], extra_roots: [],
             unverified_scopes: ['runtime_consumption'],
             identities: [SourceProvenance.hmac(key, 'before'), SourceProvenance.hmac(key, 'after')],
             scopes: { 'file:services' => { relative => 0 }, 'whole:events' => { relative => 1 } } }
    File.write(File.join(payload, 'source_inputs.json'), JSON.generate(data))
    output
  end
  history = { relative => { 'baseline' => 'before' } }
  first, second = outputs.map { |output| SourceProvenance.read(output, root: root, history: history) }
  raise 'independent keys changed source semantics' unless first == second
  raise 'omitted dirty consumer lost' unless first.dig('scopes', 'file:services', relative) == 'retained:baseline'
  raise 'whole-app consumer failed to advance' unless first.dig('scopes', 'whole:events', relative) == 'current'
  raise 'coverage uncertainty was dropped' unless first['unverified_scopes'] == ['runtime_consumption']
  rejected { SourceProvenance.read(outputs.first, root: root) }
  key_path = File.join(outputs.first, '.source-inputs.key')
  File.binwrite(key_path, Random.bytes(32))
  rejected { SourceProvenance.read(outputs.first, root: root, history: history) }
  artifact = File.join(outputs.last, 'payloads/gen-1/source_inputs.json')
  data = JSON.parse(File.read(artifact))
  data['generation'] = 2
  File.write(artifact, JSON.generate(data))
  rejected { SourceProvenance.read(outputs.last, root: root, history: history) }
end
puts 'PASS independent keys, retained/consumed scopes, unknown coverage and rejected invalid evidence'
