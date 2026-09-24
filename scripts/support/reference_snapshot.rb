# frozen_string_literal: true

require 'json'
require 'openssl'
require 'digest'
require 'woods/generation'
require 'woods/source_inputs/private_key'

# Compare published units by filename (not identifier), preserving all content
# except extraction timestamps and dependents ordering. Compare the entire graph,
# including variants/reverse_via; round only iterative PageRank's final six digits.
# Cache HMACs intentionally differ across outputs with independent private keys.
module ReferenceSnapshot
  module_function

  def payload(index)
    Woods::Generation.new(output_dir: index).payload_dir.to_s
  end

  def json(index, name)
    JSON.parse(File.read(File.join(payload(index), name)))
  end

  # Publication-failure isolation is a byte/tree contract, not equivalence.
  def fingerprint(index)
    root = payload(index)
    Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).sort.to_h do |path|
      relative = path.delete_prefix(root + '/')
      stat = File.lstat(path)
      value = if stat.file?
                ['file', Digest::SHA256.file(path).hexdigest]
              elsif stat.symlink?
                ['symlink', File.readlink(path)]
              elsif stat.directory?
                ['directory']
              else
                raise "unexpected payload entry #{relative}"
              end
      [relative, value]
    end
  end

  def read(index, semantic: true, scope: :all, cache_required: true)
    root = payload(index)
    units = {}
    indexes = {}
    Dir.glob(File.join(root, '*', '*.json')).sort.each do |path|
      next if File.basename(File.dirname(path)) == 'flows'

      name = path.delete_prefix(root + '/')
      data = JSON.parse(File.read(path))
      if File.basename(path) == '_index.json'
        data = data.select { |entry| entry.fetch('identifier').start_with?('Reference') } if scope == :fixture
        data = data.sort_by { |entry| entry.fetch('identifier') } if semantic
        indexes[name] = data
      else
        next if scope == :fixture && !data.fetch('identifier').start_with?('Reference')

        data.delete('extracted_at')
        data['dependents'] = data.fetch('dependents', []).sort_by { |entry| [entry['type'], entry['identifier']] } if semantic
        units[name] = data
      end
    end
    graph = json(index, 'dependency_graph.json')
    graph['pagerank']&.transform_values! { |score| score.round(6) } if semantic
    cache = {}
    if cache_required || File.file?(File.join(root, 'source_references.json'))
      cache = json(index, 'source_references.json')
      key = Woods::SourceInputs::PrivateKey.new(output_dir: index, create: false)
      cache.fetch('files').each do |path, record|
        actual = OpenSSL::HMAC.hexdigest('SHA256', key.bytes, File.binread(path))
        raise "cache source identity mismatch for #{path}" unless record.fetch('identity') == actual

        record.delete('identity')
      end
    end
    { 'units' => units, 'indexes' => indexes, 'graph' => graph, 'cache' => cache }
  end

  def differences(left, right, **options)
    a = read(left, **options)
    b = read(right, **options)
    a.keys.flat_map do |section|
      next [] if a[section] == b[section]

      (a.fetch(section).keys | b.fetch(section).keys).filter_map do |key|
        left_value = a.fetch(section)[key]
        right_value = b.fetch(section)[key]
        next if left_value == right_value

        if left_value.is_a?(Hash) && right_value.is_a?(Hash)
          fields = (left_value.keys | right_value.keys).select { |field| left_value[field] != right_value[field] }
          { path: "#{section}/#{key}", fields: fields,
            left: left_value.slice(*fields).inspect[0, 4000], right: right_value.slice(*fields).inspect[0, 4000] }
        else
          { path: "#{section}/#{key}", left: left_value.inspect[0, 4000], right: right_value.inspect[0, 4000] }
        end
      end
    end
  end
end
