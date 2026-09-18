# frozen_string_literal: true

require 'json'
require 'openssl'
require 'digest'

# Independent test oracle: validate each output with its private key, then
# compare named source versions rather than incomparable per-output HMAC bytes.
# Historical bytes stay in process memory and are never printed or persisted.
module SourceProvenance
  module_function

  def read(output, root:, history: {}, required: false)
    marker = JSON.parse(File.binread(File.join(output, 'generation.json')))
    relative = marker.fetch('payload')
    raise 'invalid payload path' unless safe_path?(relative)
    payload = File.join(output, relative)
    raise 'payload escapes index' unless File.realpath(payload).start_with?("#{File.realpath(output)}/")
    path = File.join(payload, 'source_inputs.json')
    unless File.exist?(path)
      raise 'source provenance artifact missing' if required
      return nil # A deliberately supported older Woods version.
    end

    data = JSON.parse(File.binread(path))
    raise 'unsupported source provenance' unless data['version'] == 1
    raise 'source provenance generation mismatch' unless data['generation'] == marker.fetch('number')
    raise 'source provenance root mismatch' unless data['root'] == File.expand_path(root)
    key_path = File.join(output, '.source-inputs.key')
    stat = File.lstat(key_path)
    raise 'insecure source identity key' unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
    key = File.binread(key_path)
    raise 'source identity key mismatch' unless key.bytesize == 32 && Digest::SHA256.hexdigest(key) == data['key_id']
    identities = data.fetch('identities')
    raise 'invalid identity table' unless identities.is_a?(Array) && identities.all? { |value| digest?(value) }
    raise 'incomplete source capture' unless data.fetch('complete') == true && data.fetch('errors').empty?
    raise 'invalid boot evidence' unless [true, false].include?(data['boot_verified'])
    normalized = data.fetch('scopes').sort.to_h.transform_values do |paths|
      paths.sort.to_h do |relative_path, index|
        raise 'invalid source path or identity reference' unless safe_path?(relative_path) &&
          index.is_a?(Integer) && index >= 0 && index < identities.size
        identity = identities.fetch(index)
        [relative_path, source_version(root, relative_path, identity, key, history)]
      end
    end
    {
      'boot_verified' => data['boot_verified'],
      'complete' => data['complete'], 'errors' => data['errors'],
      'unverified_scopes' => data.fetch('unverified_scopes').sort,
      'extra_roots' => data.fetch('extra_roots').sort, 'rules' => data.fetch('rules'),
      'scopes' => normalized
    }
  end

  def source_version(root, relative, identity, key, history)
    path = File.join(root, relative)
    if File.file?(path)
      raise 'source escapes application' unless File.realpath(path).start_with?("#{File.realpath(root)}/")
      return 'current' if hmac(key, File.binread(path)) == identity
    end
    versions = history.fetch(relative, {})
    matched = versions.find { |_label, bytes| hmac(key, bytes) == identity }
    raise "unrecognized retained source identity for #{relative}" unless matched
    "retained:#{matched.first}"
  end

  def hmac(key, bytes)
    OpenSSL::HMAC.hexdigest('SHA256', key, bytes)
  end

  def digest?(value)
    value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
  end

  def safe_path?(value)
    value.is_a?(String) && !value.empty? && !value.start_with?('/') && !value.include?("\0") &&
      value.split('/', -1).none? { |part| ['', '.', '..'].include?(part) }
  end
end
