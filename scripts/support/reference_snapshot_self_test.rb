# frozen_string_literal: true

# Run with Woods available on the load path; no Rails, Docker or app database.
require 'tmpdir'
require 'fileutils'
require_relative 'reference_snapshot'

def assert(message)
  raise message unless yield
  puts "PASS #{message}"
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
        'source_code' => 'retained', 'metadata' => { 'important' => true }, 'dependencies' => [],
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
