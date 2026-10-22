# frozen_string_literal: true

require 'tmpdir'
require_relative '../support/flow_document_inventory'

checks = 0
check = lambda do |name, &block|
  block.call
  checks += 1
  puts "PASS #{name}"
end

Dir.mktmpdir('woods-flow-inventory') do |directory|
  write = ->(name, content) { File.write(File.join(directory, name), JSON.generate(content)) }
  write.call('flow_index.json', 'PostsController#show' => 'flows/show.json')
  write.call('show.json', 'entry_point' => 'PostsController#show', 'generated_at' => 'first', 'steps' => [])

  check.call('legacy inventory excludes the entry-point index') do
    raise 'legacy documents changed' unless FlowDocumentInventory.documents(directory) == ['show.json']
  end
  check.call('legacy content snapshots normalize document timestamps') do
    expected = { 'flows/show.json' => { 'entry_point' => 'PostsController#show', 'steps' => [] } }
    raise 'legacy content changed' unless FlowDocumentInventory.artifact_map(directory) == expected
  end

  inverse = { 'Post' => { 'model' => ['PostsController#show'] } }
  write.call('by_unit.json', inverse)
  check.call('the inverted membership index is not an orphaned document') do
    documents = FlowDocumentInventory.documents(directory)
    raise "orphans: #{(documents - ['show.json']).inspect}" unless documents == ['show.json']
  end
  check.call('content snapshots retain the entire inverted membership index') do
    raise 'inverted index omitted' unless FlowDocumentInventory.artifact_map(directory)['flows/by_unit.json'] == inverse
  end

  before = FlowDocumentInventory.artifact_map(directory)
  write.call('by_unit.json', 'Post' => { 'model' => ['PostsController#create'] })
  check.call('inverted membership changes remain detectable') do
    raise 'content drift hidden' if before == FlowDocumentInventory.artifact_map(directory)
  end
  File.delete(File.join(directory, 'by_unit.json'))
  check.call('removing the auxiliary index remains detectable') do
    raise 'missing artifact hidden' if before.keys == FlowDocumentInventory.artifact_map(directory).keys
  end

  write.call('by_unit.json', 'generated_at' => { 'ruby_file' => ['PostsController#show'] })
  check.call('auxiliary index keys and values bypass document normalization') do
    snapshot = FlowDocumentInventory.artifact_map(directory) { |_content| { 'normalized_document' => true } }
    raise 'document normalizer not applied' unless snapshot['flows/show.json'] == { 'normalized_document' => true }
    expected = { 'generated_at' => { 'ruby_file' => ['PostsController#show'] } }
    raise 'auxiliary data normalized away' unless snapshot['flows/by_unit.json'] == expected
  end
  write.call('stale.json', 'entry_point' => 'PostsController#removed')
  check.call('unknown JSON documents still surface as real orphans') do
    orphaned = FlowDocumentInventory.documents(directory) - ['show.json']
    raise "orphan missed: #{orphaned.inspect}" unless orphaned == ['stale.json']
  end
  File.delete(File.join(directory, 'show.json'))
  check.call('missing referenced documents remain detectable') do
    raise 'missing document hidden' unless (['show.json'] - FlowDocumentInventory.documents(directory)) == ['show.json']
  end

  write.call('by_unit.json', {})
  check.call('an empty inverted membership index is valid') do
    raise 'empty index changed' unless FlowDocumentInventory.artifact_map(directory)['flows/by_unit.json'] == {}
  end
  write.call('by_unit.json', [])
  check.call('a non-object auxiliary index is rejected') do
    begin
      FlowDocumentInventory.artifact_map(directory)
    rescue RuntimeError => error
      next if error.message == 'by_unit.json must be an object'
      raise
    end
    raise 'invalid auxiliary shape accepted'
  end
  File.write(File.join(directory, 'by_unit.json'), '{')
  check.call('malformed auxiliary JSON fails the content comparison') do
    begin
      FlowDocumentInventory.artifact_map(directory)
    rescue JSON::ParserError
      next
    end
    raise 'invalid JSON accepted'
  end
end

puts "#{checks}/#{checks} flow inventory cases passed"
