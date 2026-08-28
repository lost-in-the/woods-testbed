# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_encoding_smoke.rb
#
# Asserts the encoding-safety contract for woods' index reader, from the app
# side. The gem-side fix lands in its own PR; this smoke is the contract that
# fix must satisfy, expressed against the real reader classes.
#
# The failure mode: a host (or container) running under LANG=C gives the
# process Encoding.default_external = US-ASCII. Every text-mode file read
# tags its bytes US-ASCII, and the first multibyte UTF-8 character in an
# index artifact then blows up JSON.parse with Encoding::InvalidByteSequence
# — or worse, silently mangles the value. Real indexes are not ASCII: git
# branch names carry accents, source comments carry em dashes. The contract:
# reading a published index under a C locale raises nothing and returns
# usable, valid-encoding data.
#
# Method: build a minimal published generation in a temp dir (generation.json
# naming a payload dir, manifest with a non-ASCII git_branch, one model unit
# whose source contains "café"), then force
# `Encoding.default_external = Encoding::US_ASCII` (restored in ensure) and
# drive the same entry points the gem's spec suite uses:
# Woods::MCP::IndexReader.new(dir), #manifest, #list_units, #find_unit,
# #dependency_graph.
#
# Section 3 additionally launches the packaged stdio executable the way an
# MCP client does: /woods-gem/exe/woods-mcp spawned with LANG=C / LC_ALL=C,
# fed a JSON-RPC initialize + tools/call over stdin. It asserts protocol-only
# stdout (every line valid JSON-RPC), a non-corrupt_artifact response from
# the manifest-serving `structure` tool, and that the café value round-trips
# intact through the `lookup` response. Contract-first for the packaged-
# executable half of the fix, gem PR lost-in-the/woods#247: until it lands
# the executable's C-locale manifest read dies and structure answers
# corrupt_artifact, while unit data loaded at boot already survives.
#
# Runs against whatever woods the variant's bundle mounts (WOODS_GEM_PATH),
# so it gates the fix per variant. Expected to FAIL, with the exact
# exception in the FAIL line, until the gem-side fix lands.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'woods/dependency_graph'
require 'woods/mcp/index_reader'

results = []

def assert(name, &block)
  block.call
  puts "  PASS  #{name}"
  true
rescue StandardError => e
  puts "  FAIL  #{name}: #{e.class}: #{e.message}"
  false
end

# ── Section 1: build the published-generation fixture ────────────────────

puts '=== Section 1: minimal published index fixture ==='

fixture_root = Dir.mktmpdir('woods_encoding_smoke')
index_dir    = File.join(fixture_root, 'woods')
payload_dir  = File.join(index_dir, 'payloads/gen-1')
FileUtils.mkdir_p(File.join(payload_dir, 'models'))

# The payload pointer is what makes this a published generation rather than a
# flat index: the reader must resolve every artifact through the directory
# generation.json names, not the index root.
File.write(File.join(index_dir, 'generation.json'),
           JSON.generate('number' => 1, 'token' => 'encoding-smoke', 'reason' => 'smoke',
                         'payload' => 'payloads/gen-1'))

manifest = {
  'total_units' => 1,
  'counts' => { 'models' => 1 },
  'git_branch' => 'feature/café'
}
File.write(File.join(payload_dir, 'manifest.json'), JSON.generate(manifest))

File.write(File.join(payload_dir, 'dependency_graph.json'),
           JSON.generate('nodes' => { 'Post' => { 'type' => 'model' } },
                         'edges' => { 'Post' => [] }))

File.write(File.join(payload_dir, 'models/_index.json'),
           JSON.generate([{ 'identifier' => 'Post', 'file_path' => 'app/models/post.rb' }]))

unit_source = <<~RUBY
  class Post < ApplicationRecord
    # Header shown on the café index page.
  end
RUBY

# Filenames follow the reader's own reconstruction: sanitized identifier plus
# an 8-char SHA256 of the identifier, so find_unit lands on a real file.
unit_name = "Post_#{Digest::SHA256.hexdigest('Post')[0, 8]}.json"
File.write(File.join(payload_dir, 'models', unit_name),
           JSON.generate('identifier' => 'Post', 'file_path' => 'app/models/post.rb',
                         'source_code' => unit_source, 'metadata' => {}))

puts "fixture: #{index_dir}"
puts

results << assert('fixture manifest on disk carries a non-ASCII git_branch as valid UTF-8') do
  raw = File.read(File.join(payload_dir, 'manifest.json'), encoding: 'UTF-8')
  branch = JSON.parse(raw)['git_branch']
  raise "git_branch is #{branch.inspect}" unless branch == 'feature/café' && branch.valid_encoding?
end

# ── Section 2: the reader under a simulated C-locale host ────────────────

puts
puts '=== Section 2: IndexReader under Encoding.default_external = US-ASCII ==='

original_external = Encoding.default_external
begin
  Encoding.default_external = Encoding::US_ASCII

  reader = Woods::MCP::IndexReader.new(index_dir)

  results << assert('constructor accepts the payload-pointer index') { raise 'nil reader' if reader.nil? }

  results << assert('payload_dir resolves into the generation payload (pointer followed)') do
    resolved = reader.payload_dir
    raise "resolved to #{resolved}" unless resolved.join('manifest.json').file?
  end

  results << assert('#manifest parses without InvalidByteSequenceError and preserves "feature/café"') do
    branch = reader.manifest['git_branch']
    raise "git_branch is #{branch.inspect}" unless branch == 'feature/café'
    raise "#{branch.inspect} not valid #{branch.encoding}" unless branch.valid_encoding?
  end

  results << assert('#list_units(type: "model") returns the Post entry') do
    entries = reader.list_units(type: 'model')
    raise "got #{entries.inspect}" unless entries.one? { |e| e['identifier'] == 'Post' }
  end

  results << assert('#find_unit("Post") returns source_code containing "café" as valid UTF-8') do
    unit = reader.find_unit('Post')
    raise 'unit not found' unless unit
    source = unit['source_code']
    raise "source missing café: #{source.inspect}" unless source&.include?('café')
    raise "#{source.encoding} not valid" unless source.valid_encoding?
  end

  results << assert('#dependency_graph loads through the payload') do
    graph = reader.dependency_graph
    raise "got #{graph.class}" unless graph.is_a?(Woods::DependencyGraph)
  end
ensure
  Encoding.default_external = original_external
end

# ── Section 3: packaged stdio executable under LANG=C / LC_ALL=C ─────────
#
# Contract-first (gem PR lost-in-the/woods#247): launches the packaged
# executable as a real MCP client would, under a C locale, and asserts the
# wire contract. Protocol purity and the café round-trip through lookup hold
# even against today's gem — unit data is loaded at boot through UTF-8-safe
# reads. The failure this section gates is the manifest-serving `structure`
# tool: the child's C-locale manifest read dies and it answers
# corrupt_artifact. stderr is kept separate; warnings are allowed there,
# stdout must stay protocol-only.

MCP_EXECUTABLE = File.join(ENV.fetch('WOODS_GEM_PATH', '/woods-gem'), 'exe', 'woods-mcp')
MCP_CHILD_TIMEOUT = 20 # seconds before the watchdog kills the child, so the smoke cannot hang

# Spawn the executable and run one JSON-RPC conversation against it.
#
# All requests are written up front and stdin is closed, so the transport
# sees EOF after the last line and exits on its own; a child that never
# finishes is killed by the watchdog. stderr is drained on its own thread so
# warnings cannot fill the pipe and deadlock the child.
def json_rpc_exchange(executable, index_dir, requests)
  stdout_lines = []
  stderr_text = []
  env = {
    'LANG' => 'C',
    'LC_ALL' => 'C',
    'OPENAI_API_KEY' => nil,                       # no provider autodetect
    'OLLAMA_BASE_URL' => 'http://127.0.0.1:19999'  # dead port, as the gem's own CLI specs use
  }
  Open3.popen3(env, executable, index_dir, pgroup: true) do |stdin, stdout, stderr, wait_thr|
    stderr_drain = Thread.new { stderr_text << stderr.read }
    requests.each { |request| stdin.puts(JSON.generate(request)) }
    stdin.close

    watchdog = Thread.new do
      sleep MCP_CHILD_TIMEOUT
      begin
        Process.kill('TERM', -wait_thr.pid) # negative pid: the whole process group
        wait_thr.join(5)
        Process.kill('KILL', -wait_thr.pid) if wait_thr.alive?
      rescue StandardError
        nil # the child already exited
      end
    end

    while (line = stdout.gets)
      stdout_lines << line.chomp
    end

    watchdog.kill if watchdog&.alive?
    watchdog&.join(5)
    stderr_drain.join(5)
    stdout.close
    stderr.close
  end
  [stdout_lines, stderr_text.join]
end

puts
puts '=== Section 3: packaged stdio executable under LANG=C / LC_ALL=C ==='

results << assert('packaged executable exists and is runnable') do
  raise "not found or not executable: #{MCP_EXECUTABLE} (set WOODS_GEM_PATH)" unless File.executable?(MCP_EXECUTABLE)
end

initialize_request = {
  jsonrpc: '2.0', id: 1, method: 'initialize',
  params: { protocolVersion: '2024-11-05', capabilities: {},
            clientInfo: { name: 'woods-encoding-smoke', version: '1.0' } }
}
initialized_notification = { jsonrpc: '2.0', method: 'notifications/initialized' }
lookup_call = {
  jsonrpc: '2.0', id: 2, method: 'tools/call',
  params: { name: 'lookup', arguments: { identifier: 'Post' } }
}
# structure is the tool that serves the manifest — the read that dies under a
# C locale today. lookup/search serve unit data loaded at boot and already
# survive, so they are the round-trip surface, not the contract gate.
structure_call = {
  jsonrpc: '2.0', id: 3, method: 'tools/call',
  params: { name: 'structure', arguments: {} }
}

stdout_lines, stderr_text = json_rpc_exchange(
  MCP_EXECUTABLE, index_dir,
  [initialize_request, initialized_notification, lookup_call, structure_call]
)

parsed_messages = stdout_lines.map do |line|
  next if line.strip.empty?

  begin
    JSON.parse(line)
  rescue JSON::ParserError => e
    raise "non-JSON stdout line: #{line[0, 120].inspect} (#{e.class})"
  end
end.compact

results << assert('executable boots and answers initialize under a C locale') do
  initialize_response = parsed_messages.grep(Hash).find { |message| message['id'] == 1 }
  raise "no initialize response on stdout (stderr: #{stderr_text[0, 300].inspect})" unless initialize_response
  raise "initialize errored: #{initialize_response['error'].inspect}" if initialize_response['error']
end

results << assert('every stdout line is valid JSON-RPC (protocol-only stdout)') do
  raise 'no stdout at all (stderr: ' + stderr_text[0, 300].inspect + ')' if parsed_messages.empty?

  bad = parsed_messages.grep(Hash).reject { |message| message['jsonrpc'] == '2.0' }
  raise "messages without jsonrpc 2.0 envelope: #{bad.inspect}" unless bad.empty?
end

structure_response = parsed_messages.grep(Hash).find { |message| message['id'] == 3 }

results << assert('structure (manifest-serving tool) is not corrupt_artifact') do
  raise 'no response to tools/call structure' unless structure_response

  result = structure_response['result'] || {}
  raise "structure errored at the JSON-RPC layer: #{structure_response['error'].inspect}" if structure_response['error']
  raise "structure result is not a Hash: #{result.inspect}" unless result.is_a?(Hash)
  next unless result['isError']

  code = result.dig('_meta', 'error_code') || result.dig('structuredContent', 'error_code')
  raise "tool error (#{code}): #{result.dig('content', 0, 'text').to_s[0, 200].inspect}"
end

lookup_response = parsed_messages.grep(Hash).find { |message| message['id'] == 2 }

results << assert('café round-trips intact through the lookup response') do
  raise 'no lookup response to check' unless lookup_response

  result = lookup_response['result'] || {}
  if result['isError']
    code = result.dig('_meta', 'error_code') || result.dig('structuredContent', 'error_code')
    raise "lookup tool error (#{code}): #{result.dig('content', 0, 'text').to_s[0, 200].inspect}"
  end

  text = result.dig('content', 0, 'text')
  raise 'no content text in lookup response' unless text

  raise "#{text.encoding} output not valid" unless text.valid_encoding?
  raise "café missing or mangled in response: #{text[0, 200].inspect}" unless text.include?('café')
end

# ── Summary ──

puts
puts '=== Summary ==='
passed = results.count(true)
failed = results.count(false)
puts "passed: #{passed}    failed: #{failed}    total: #{results.size}"
puts "fixture left in place for inspection: #{fixture_root}" unless failed.zero?
exit(failed.zero? ? 0 : 1)
