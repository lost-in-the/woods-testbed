# frozen_string_literal: true

# Small process contracts; no Rails boot, server, database, provider or user index.
# Synthetic passes establish no live Rails 8.0/6.0/7.2 or bounded Canopy acceptance.
# Uses the sibling Woods checkout's REAL saved-report store, Markdown renderer
# and RangeDiff/Report over synthetic units. Held-lock cases use the REAL
# PublishedIndex on disposable manifests, never an app cache. Rails, Map
# Repository, Rack responses and other PublishedIndex cases are adapters. Their HTML follows Map's range/_changed,
# components/_table, units/_since and units/_code_view partials.
#
# timeout --kill-after=5s 120s ruby scripts/tools/woods_map_impact_smoke_self_test.rb --woods /path/to/woods
# Each fixture has an independent finite deadline. TERM/INT cleanup owns only
# its spawned process group, including when the signal arrives during spawn.
# --smoke PATH --case NAME can exercise a negative control (including the older
# general smoke's successful missing-Map skip) without treating absence as red.
require 'json'
require 'optparse'
require 'rbconfig'
require 'tmpdir'
require 'nokogiri' # fail on a missing real parser before claiming a negative-case result


# A self-test-local supervisor: signal handlers only record a request, so TERM
# cannot unwind the gap between spawn and registration of the owned group.
# No changes to the shared MCP helper or unrelated process groups are needed.
module ImpactSmokeChildren
  Result = Struct.new(:stdout_lines, :stderr_text, :status, :timed_out, :signal, :during_launch, keyword_init: true)
  module_function

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def signal_group(pid, signal)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    nil
  end

  def reap(pid)
    Process.waitpid2(pid, Process::WNOHANG)&.last
  rescue Errno::EINTR
    nil
  end

  def cleanup(pid, status)
    # One shared 1.5-second budget, below the outer timeout's five-second grace.
    deadline = now + 1.5
    signal_group(pid, 'TERM')
    grace = now + 0.3
    while now < grace
      status ||= reap(pid)
      sleep 0.01
    end
    # A reaped leader may have left a descendant holding the group's pipes.
    signal_group(pid, 'KILL')
    until status || now >= deadline
      status = reap(pid)
      sleep 0.01 unless status
    end
    status
  end

  def capture(command:, timeout:, env: {}, spawn: Process.method(:spawn))
    stdout_text = +''
    stderr_text = +''
    handles = []
    readers = {}
    previous_handlers = {}
    stopped = nil
    launching = stopped_while_launching = false
    pid = status = nil
    completed = timed_out = false
    begin
      %w[TERM INT].each do |signal|
        previous_handlers[signal] = Signal.trap(signal) do
          stopped ||= signal
          stopped_while_launching ||= launching
        end
      end
      stdout, stdout_write = IO.pipe
      handles.concat([stdout, stdout_write])
      stderr, stderr_write = IO.pipe
      handles.concat([stderr, stderr_write])
      readers = { stdout => stdout_text, stderr => stderr_text }
      # A signal during this call is recorded; the returned PID is always
      # registered before control reaches cleanup. Only this group is owned.
      launching = true
      pid = spawn.call(env, *command, in: File::NULL, out: stdout_write, err: stderr_write, pgroup: true)
      launching = false
      stdout_write.close
      stderr_write.close
      deadline = now + timeout
      loop do
        status ||= reap(pid)
        completed = status && readers.empty?
        break if stopped || completed
        if now >= deadline
          timed_out = true
          break
        end
        begin
          ready = IO.select(readers.keys, nil, nil, [deadline - now, 0.02].min.clamp(0, 0.02))
          ready&.first&.each do |io|
            chunk = io.read_nonblock(16_384, exception: false)
            if chunk.nil?
              readers.delete(io)
            elsif chunk != :wait_readable
              readers.fetch(io) << chunk
            end
          end
        rescue Errno::EINTR
          # Return to the recorded termination/deadline check.
          next
        end
      end
    ensure
      begin
        status = cleanup(pid, status) if pid && (!completed || stopped)
      ensure
        handles.each { |io| io.close unless io.closed? }
        previous_handlers.each { |signal, handler| Signal.trap(signal, handler) }
      end
    end
    raise 'Owned self-test child was not reaped within bounded cleanup' unless status

    Result.new(stdout_lines: stdout_text.lines.map(&:chomp), stderr_text: stderr_text,
               status: status, timed_out: timed_out, signal: stopped, during_launch: stopped_while_launching)
  end
end

# Fixed dummy Ruby, written as a file and run normally, never extracted/eval'd.
# Its leader resists TERM (requiring supervisor KILL); the descendant exits on
# group TERM and is reaped by the leader before the bounded KILL grace expires.
TERMINATION_CHILD = <<~'RUBY'
  require 'json'
  def stamp(pid)
    File.read("/proc/#{pid}/stat").rpartition(') ').last.split.fetch(19)
  end
  root = ARGV.fetch(0)
  trap('TERM') {}
  descendant = fork do
    trap('TERM', 'DEFAULT')
    loop { sleep 1 }
  end
  File.write(File.join(root, 'owned-pids.json'), JSON.generate(
    'group' => Process.getpgrp,
    'leader' => { 'pid' => Process.pid, 'start' => stamp(Process.pid) },
    'descendant' => { 'pid' => descendant, 'start' => stamp(descendant) }
  ))
  loop do
    begin
      Process.waitpid(descendant, Process::WNOHANG)
    rescue Errno::ECHILD
      # Keep the leader alive until the supervisor kills and reaps it.
    end
    sleep 0.01
  end
RUBY

def private_process(record, group)
  fields = File.read("/proc/#{record.fetch('pid')}/stat").rpartition(') ').last.split
  fields.fetch(19) == record.fetch('start') && fields.fetch(2).to_i == group
rescue Errno::ENOENT, Errno::ESRCH
  false
end

def termination_case(name, options, root)
  command = ['timeout', '--kill-after=5s', '2s', RbConfig.ruby, __FILE__,
             '--woods', options.fetch(:woods), '--termination-control', root]
  command << '--termination-during-launch' if name == 'outer_timeout_during_launch'
  started = ImpactSmokeChildren.now
  owned = nil
  begin
    result = ImpactSmokeChildren.capture(command: command, timeout: 8, env: { 'WOODS_MAP_TOKEN' => nil })
    exit(128 + Signal.list.fetch(result.signal)) if result.signal
    elapsed = ImpactSmokeChildren.now - started
    owned = JSON.parse(File.read(File.join(root, 'owned-pids.json')))
    group = owned.fetch('group')
    raise 'Invalid private fixture group' unless group.is_a?(Integer) && group > 1 && group == owned.dig('leader', 'pid')
    identities = owned.values_at('leader', 'descendant')
    gone = identities.none? { |record| private_process(record, group) }
    if name == 'outer_timeout_during_launch'
      termination = JSON.parse(File.read(File.join(root, 'termination.json')))
      unless termination['signal'] == 'TERM' && termination['during_launch'] == true
        raise 'TERM was not delivered during the controlled launch window'
      end
    end
    unless !result.timed_out && result.status.exitstatus == 124 && elapsed < 6.5 && gone
      raise "#{name}: external timeout failed to clean/reap private leader and descendant within its grace"
    end
    puts "PASS #{name} external timeout cleaned and reaped its private group (#{elapsed.round(2)}s)"
  ensure
    # Failure containment also uses only PID/start/group identities created by
    # this case, never a broad process search or a container-wide kill.
    pid_file = File.join(root, 'owned-pids.json')
    owned ||= JSON.parse(File.read(pid_file)) if File.file?(pid_file)
    if owned && owned.values_at('leader', 'descendant').any? { |record| private_process(record, owned.fetch('group')) }
      ImpactSmokeChildren.signal_group(owned.fetch('group'), 'TERM')
      sleep 0.3
      ImpactSmokeChildren.signal_group(owned.fetch('group'), 'KILL')
    end
  end
end

options = { woods: File.expand_path('../../../woods', __dir__),
            smoke: File.expand_path('../woods_map_impact_smoke.rb', __dir__) }
OptionParser.new do |parser|
  parser.on('--woods PATH') { |path| options[:woods] = File.expand_path(path) }
  parser.on('--smoke PATH') { |path| options[:smoke] = File.expand_path(path) }
  parser.on('--case NAME') { |name| options[:case] = name }
  parser.on('--termination-control DIRECTORY') { |path| options[:termination_control] = path }
  parser.on('--termination-during-launch') { options[:termination_during_launch] = true }
end.parse!
abort 'Unexpected self-test arguments' unless ARGV.empty?
if options[:termination_control]
  root = options.fetch(:termination_control)
  dummy = File.join(root, 'termination_child.rb')
  File.write(dummy, TERMINATION_CHILD)
  spawn = Process.method(:spawn)
  if options[:termination_during_launch]
    spawn = lambda do |*arguments, **keywords|
      pid = Process.spawn(*arguments, **keywords)
      # Model a signal before spawn returns its PID to the supervisor. The
      # outer two-second timeout fires during this bounded three-second pause.
      ready_deadline = ImpactSmokeChildren.now + 0.5
      until File.file?(File.join(root, 'owned-pids.json')) || ImpactSmokeChildren.now >= ready_deadline
        sleep 0.01
      end
      File.write(File.join(root, 'launch-window'), pid.to_s)
      sleep 3
      pid
    end
  end
  result = ImpactSmokeChildren.capture(command: [RbConfig.ruby, dummy, root], timeout: 60, spawn: spawn)
  File.write(File.join(root, 'termination.json'), JSON.generate('signal' => result.signal, 'during_launch' => result.during_launch))
  exit(128 + Signal.list.fetch(result.signal)) if result.signal
  abort 'Termination control returned before its external timeout'
end
woods_lib = File.join(options.fetch(:woods), 'lib')
abort 'Provide --woods PATH with the impact store, renderers, range_diff, options, artifacts and report' unless
  %w[store renderers range_diff options artifacts report].all? { |name| File.file?(File.join(woods_lib, "woods/impact/#{name}.rb")) }

fixture = <<~'RUBY'
  $stdout.sync = true
  require 'cgi'
  require 'digest'
  require 'fileutils'
  require 'json'
  require 'pathname'
  require 'uri'
  require 'woods/version'
  require 'woods/impact/store'
  require 'woods/impact/renderers'
  require 'woods/impact/range_diff'
  require 'woods/impact/options'
  require 'woods/impact/artifacts'
  require 'woods/impact/report'
  real_published_index = Woods::PublishedIndex
  Woods.send(:remove_const, :PublishedIndex) # adapter below; keep the real class for held-lock cases

  smoke, scenario, root = ARGV
  ARGV.clear
  raise 'child environment was replaced' unless ENV['IMPACT_SELF_TEST_INHERITED'] == 'retained'
  raise 'caller token reached child' if ENV.key?('WOODS_MAP_TOKEN')
  ENV['WOODS_MAP_TOKEN'] = 'synthetic-private-token'
  app_root = Pathname.new(root).join('app')
  index = app_root.join('tmp/woods')
  FileUtils.mkdir_p(index)
  File.write(index.join('generation.json'), JSON.generate('number' => 2, 'payload' => 'payloads/gen-2'))

  template = scenario == 'escaped_identifier' ? 'app/views/posts/_café &+100%?.html.erb' : 'app/views/posts/_card.html.erb'
  identifier = template.delete_prefix('app/views/')
  old_source = "<p>PRIVATE_TEMPLATE_BODY</p>\n<p>Before</p>\n"
  new_source = "<p>PRIVATE_TEMPLATE_BODY</p>\n<p>After</p>\n"
  if %w[two_hunks partial_hunks].include?(scenario)
    old_source += "<p>Unchanged</p>\n<p>Before second</p>\n"
    new_source += "<p>Unchanged</p>\n<p>After second</p>\n"
  elsif scenario == 'deletion_at_start'
    old_source = "<p>Removed</p>\n" + new_source
  elsif %w[deletion_only wrong_removal_count].include?(scenario)
    old_source += "<p>Removed</p>\n"
    new_source = old_source.lines.first(2).join
  end
  units = [old_source, new_source].map do |source|
    { 'identifier' => identifier, 'type' => 'view_template', 'file_path' => template,
      'source_code' => source, 'metadata' => {}, 'dependencies' => [] }
  end
  inventories = units.map { |unit| { unit.values_at('identifier', 'type') => unit } }
  witness_cases = %w[witness_to witness_from witness_chain mixed_generation mixed_witness wrong_side_root untyped_root
                     empty_edges malformed_edge broken_chain wrong_witness_target wrong_distance]
  if witness_cases.include?(scenario)
    dependent = { 'identifier' => 'PostsController', 'type' => 'controller', 'source_code' => "render\n",
                  'metadata' => {}, 'dependencies' => [] }
    inventories.each { |inventory| inventory[dependent.values_at('identifier', 'type')] = dependent }
    if scenario == 'witness_chain'
      caller_unit = dependent.merge('identifier' => 'RenderService', 'type' => 'service')
      inventories.each { |inventory| inventory[caller_unit.values_at('identifier', 'type')] = caller_unit }
    end
  end
  if %w[witness_from wrong_side_root].include?(scenario)
    removed = { 'identifier' => 'OldService', 'type' => 'service', 'source_code' => "old\n",
                'metadata' => {}, 'dependencies' => [] }
    inventories.first[removed.values_at('identifier', 'type')] = removed
  end
  if scenario.include?('source_unknown')
    unavailable = { 'identifier' => 'OtherService', 'type' => 'service', 'source_code' => nil,
                    'metadata' => {}, 'dependencies' => [] }
    inventories.each { |inventory| inventory[unavailable.values_at('identifier', 'type')] = unavailable }
  end
  if scenario == 'classification_unknowns'
    classified = { 'identifier' => 'UnclassifiedUnit', 'type' => 'custom_unit', 'source_code' => "before\n",
                   'metadata' => { 'future_fact' => 'before' }, 'dependencies' => [] }
    inventories.first[classified.values_at('identifier', 'type')] = classified
    inventories.last[classified.values_at('identifier', 'type')] = classified.merge(
      'source_code' => "after\n", 'metadata' => { 'future_fact' => 'after' }
    )
  end
  manifests = [1, 2].to_h do |number|
    family = { 'view_template' => 'view_templates', 'controller' => 'controllers', 'service' => 'services', 'custom_unit' => 'custom_units' }
    counts = inventories.fetch(number - 1).values.each_with_object(Hash.new(0)) { |unit, result| result[family.fetch(unit['type'])] += 1 }
    [number, { 'counts' => counts, 'total_units' => counts.values.sum,
               'git_sha' => (number == 1 ? 'a' : 'b') * 40 }]
  end
  checksums = manifests.transform_values { |manifest| Digest::SHA256.hexdigest(JSON.generate(manifest)) }
  endpoints = [1, 2].map do |number|
    { 'selector' => "gen:#{number}", 'generation' => number,
      'git_sha' => manifests.fetch(number).fetch('git_sha'), 'manifest_checksum' => checksums.fetch(number) }
  end
  changes = Woods::Impact::RangeDiff.new(*inventories).changes
  # Let the real producer build schema-1 keys and deferred/unbound unknowns.
  # Only computed evidence is synthetic; this never invokes a task or publisher.
  context = { 'endpoint' => 'to', 'generation' => 2 }
  computed = {
    'parameters' => Woods::Impact::Options.new.to_h.merge('mode' => 'range',
                                                       'artifact_max_bytes' => Woods::Impact::Artifacts::MAX_BYTES),
    'affected' => [], 'flows' => [], 'tables' => [],
    'templates' => [units.last.slice('identifier', 'type').merge(context).merge('evidence' => [{ 'kind' => 'selected_unit' }])],
    'risks' => [], 'tests' => [],
    'coverage' => { 'affected' => 'bounded', 'flows' => 'partial', 'tables' => 'partial',
                    'templates' => 'partial', 'risks' => 'partial', 'tests' => 'partial' },
    'unknowns' => %w[expanded_membership_only flow_index_unavailable instance_variable_mismatch_not_computed
                     graph_analysis_unavailable database_access_not_exhaustive render_references_only
                     test_suggestions_only].map { |kind| context.merge('kind' => kind) }
  }
  endpoint_unknowns = inventories.zip(%w[from to]).flat_map do |inventory, side|
    Woods::Impact::Endpoint.new(nil).unknowns(inventory, side)
  end
  data = JSON.parse(Woods::Impact::Report.new({ 'from' => endpoints.first, 'to' => endpoints.last }, changes,
                                            unknowns: endpoint_unknowns, computed: computed).to_json)
  if witness_cases.include?(scenario)
    side = scenario == 'witness_from' ? 'from' : 'to'
    generation = side == 'from' ? 1 : 2
    identity = { 'identifier' => 'PostsController', 'type' => 'controller' }
    origin = if %w[witness_from wrong_side_root].include?(scenario)
               { 'identifier' => 'OldService', 'type' => 'service' }
             else
               { 'identifier' => identifier, 'type' => 'view_template' }
             end
    data['affected'] = [identity.merge('endpoint' => side, 'generation' => generation, 'distance' => 1, 'weight' => nil,
      'paths' => [{ 'root' => origin, 'endpoint' => side, 'generation' => generation,
                   'edges' => [{ 'source' => identity, 'target' => origin, 'via' => 'view_render' }] }])]
    if scenario == 'witness_chain'
      caller_identity = { 'identifier' => 'RenderService', 'type' => 'service' }
      data['affected'].first.merge!(caller_identity).merge!('distance' => 2)
      data['affected'].first['paths'].first['edges'] << { 'source' => caller_identity, 'target' => identity, 'via' => 'constant' }
    end
  end
  # Legitimate partial evidence is not a skip or an empty-result fallback.
  if scenario == 'partial_evidence'
    data['unknowns'] << { 'kind' => 'graph_unavailable', 'endpoint' => 'to', 'generation' => 2 }
    data['coverage']['affected'] = 'partial'
  end
  case scenario
  when 'missing_coverage_key' then data['coverage'].delete('flows')
  when 'invalid_coverage_value' then data['coverage']['affected'] = 'complete'
  when 'missing_focus_unknown' then data['unknowns'].reject! { |item| item['feature'] == 'focus' }
  when 'missing_commits_unknown' then data['unknowns'].reject! { |item| item['feature'] == 'commits' }
  when 'missing_snapshot_unknown' then data['unknowns'].reject! { |item| item['kind'] == 'snapshot_binding_unavailable' }
  when 'partial_hunks'
    ranges = data['changed'].first.fetch('source_changes')
    raise 'fixture needs two real separated hunks' unless ranges['hunks'].size == 2 && ranges['coverage'] == 'complete'
    ranges['hunks'] = ranges['hunks'].first(1)
    ranges['removed_lines'], ranges['added_lines'] = ranges['hunks'].first.values_at('before', 'after').map(&:last)
  when 'wrong_schema' then data['schema_version'] = 99
  when 'missing_array' then data.delete('templates')
  when 'malformed_array' then data['affected'] = [nil]
  when 'malformed_change_record'
    data['changed'] << data['changed'].first.merge('identifier' => 'posts/other.html.erb', 'facets' => nil)
  when 'wrong_endpoint' then data['range']['from']['generation'] = 2
  when 'wrong_selector' then data['range']['from']['selector'] = 'now'
  when 'wrong_checksum' then data['range']['from']['manifest_checksum'] = 'c' * 64
  when 'wrong_git_sha' then data['range']['to']['git_sha'] = 'c' * 40
  when 'missing_change' then data['changed'] = []
  when 'typed_collision' then data['changed'].first['type'] = 'service'
  when 'duplicate_change' then data['changed'] *= 2
  when 'metadata_only'
    data['changed'].first['facets'] = ['metadata']
    data['changed'].first.delete('source_changes')
  when 'missing_hunks' then data['changed'].first.delete('source_changes')
  when 'truncated_hunks' then data['changed'].first['source_changes']['coverage'] = 'truncated'
  when 'bad_hunk' then data['changed'].first['source_changes']['hunks'].first['after'] = [2000, 1]
  when 'float_hunk' then data['changed'].first['source_changes']['hunks'].first['after'][0] = 2.0
  when 'wrong_source_stats' then data['changed'].first['diff_stats']['source_after']['bytes'] += 1
  when 'mixed_unknown_generation'
    data['unknowns'] << { 'kind' => 'graph_unavailable', 'endpoint' => 'to', 'generation' => 1 }
  when 'mixed_generation' then data['affected'].first['generation'] = 1
  when 'mixed_witness' then data['affected'].first['paths'].first['generation'] = 1
  when 'untyped_root' then data['affected'].first['paths'].first['root'] = {}
  when 'empty_edges' then data['affected'].first['paths'].first['edges'] = []
  when 'malformed_edge' then data['affected'].first['paths'].first['edges'] = [{ 'source' => 'PostsController' }]
  when 'broken_chain'
    data['affected'].first['paths'].first['edges'].first['target'] = { 'identifier' => 'Elsewhere', 'type' => 'service' }
  when 'wrong_witness_target'
    data['affected'].first['paths'].first['edges'].first['source'] = { 'identifier' => 'Elsewhere', 'type' => 'controller' }
  when 'wrong_distance' then data['affected'].first['distance'] = 2
  when 'unknown_missing_generation'
    data['unknowns'] << { 'kind' => 'graph_unavailable', 'endpoint' => 'to' }
  when 'unknown_missing_context'
    data['unknowns'] << { 'kind' => 'graph_unavailable' }
  when 'unknown_missing_endpoint'
    data['unknowns'] << { 'kind' => 'graph_unavailable', 'generation' => 2 }
  when 'unknown_invalid_endpoint'
    data['unknowns'] << { 'kind' => 'graph_unavailable', 'endpoint' => 'head', 'generation' => 2 }
  when 'unknown_float_generation', 'unknown_string_generation', 'unknown_null_generation'
    generation = { 'unknown_float_generation' => 2.0, 'unknown_string_generation' => '2', 'unknown_null_generation' => nil }.fetch(scenario)
    data['unknowns'] << { 'kind' => 'graph_unavailable', 'endpoint' => 'to', 'generation' => generation }
  when 'unknown_empty_kind' then data['unknowns'] << { 'kind' => '', 'endpoint' => 'to', 'generation' => 2 }
  when 'unknown_missing_kind' then data['unknowns'] << { 'endpoint' => 'to', 'generation' => 2 }
  when 'deferred_unknown_missing_feature' then data['unknowns'] << { 'kind' => 'not_computed' }
  when 'deferred_unknown_bad_feature' then data['unknowns'] << { 'kind' => 'not_computed', 'feature' => 'invented' }
  when 'snapshot_unknown_extra_field' then data['unknowns'] << { 'kind' => 'snapshot_binding_unavailable', 'extra' => true }
  when 'classification_unknown_missing_identity' then data['unknowns'] << { 'kind' => 'unclassified_source' }
  when 'classification_unknown_empty_keys'
    data['unknowns'] << units.last.slice('identifier', 'type').merge('kind' => 'unclassified_metadata', 'metadata_keys' => [])
  when 'untyped_source_unknown'
    data['unknowns'].find { |item| item['kind'] == 'source_unavailable' }.delete('type')
  when 'source_unknown_missing_context'
    data['unknowns'].find { |item| item['kind'] == 'source_unavailable' }.delete('endpoint')
  when 'source_unknown_untyped_with_generation'
    data['unknowns'] << { 'kind' => 'source_unavailable', 'endpoint' => 'to', 'generation' => 2 }
  when 'source_unknown_with_generation'
    data['unknowns'].find { |item| item['kind'] == 'source_unavailable' }['generation'] = 1
  when 'source_unknown_missing_identifier'
    data['unknowns'].find { |item| item['kind'] == 'source_unavailable' }.delete('identifier')
  when 'source_unknown_empty_identifier'
    data['unknowns'].find { |item| item['kind'] == 'source_unavailable' }['identifier'] = ''
  when 'source_unknown_empty_type'
    data['unknowns'].find { |item| item['kind'] == 'source_unavailable' }['type'] = ''
  when 'source_unknown_nonstring_type'
    data['unknowns'].find { |item| item['kind'] == 'source_unavailable' }['type'] = 7
  when 'source_unknown_invalid_endpoint'
    data['unknowns'].find { |item| item['kind'] == 'source_unavailable' }['endpoint'] = 'head'
  when 'source_unknown_extra_field'
    data['unknowns'].find { |item| item['kind'] == 'source_unavailable' }['extra'] = true
  end

  store = Woods::Impact::Store.new(index)
  # Invalid envelopes cannot be written by Store#save; place deliberately corrupt
  # bytes only in this disposable fixture to exercise Store#read and smoke checks.
  json = JSON.generate(data)
  id = Digest::SHA256.hexdigest(json)
  if %w[wrong_schema malformed_json].include?(scenario)
    json = '{broken' if scenario == 'malformed_json'
    id = Digest::SHA256.hexdigest(json)
    target = store.path_for(id)
    FileUtils.mkdir_p(target.dirname, mode: 0o700)
    File.write(target, json, perm: 0o600)
  else
    id = store.save(json)
  end
  markdown_path = Pathname.new(root).join('impact.md')
  markdown = begin
    Woods::Impact::Renderers.markdown(data)
  rescue ArgumentError, NoMethodError, TypeError
    'malformed fixture report'
  end
  markdown = "## Change impact\nSKIP no comparison\n" if scenario == 'wrong_markdown'
  markdown = markdown.sub('gen:1', 'gen:99') if scenario == 'stale_markdown'
  File.write(markdown_path, markdown)
  File.unlink(store.path_for(id)) if scenario == 'missing_saved_report'
  File.write(store.path_for(id), json + ' ') if scenario == 'bad_digest'
  File.unlink(markdown_path) if scenario == 'missing_markdown'

  module Rails
    def self.version; 'synthetic-rails'; end
    def self.application; :synthetic_application; end
    class << self; attr_accessor :root; end
  end
  Rails.root = app_root
  module WoodsMap
    VERSION = 'synthetic-map'
    Engine = Class.new
    class << self; attr_accessor :configuration; end
    class Repository
      class << self; attr_accessor :fixture; end
      def self.open(path)
        raise 'repository index changed' unless File.realpath(path) == fixture.fetch(:index).realpath.to_s
        yield new(2)
      end
      def initialize(number); @number = number; end
      def generation_number
        self.class.fixture[:scenario] == 'head_not_current' ? 3 : @number
      end
      def index_dir; self.class.fixture.fetch(:index); end
      def manifest; self.class.fixture.fetch(:manifests).fetch(@number); end
      def unit(identifier, type:)
        self.class.fixture.fetch(:inventories).fetch(@number - 1)[[identifier, type]]
      end
      def file_owners(path)
        unit = self.class.fixture.fetch(:units).last
        path == unit['file_path'] ? [unit.slice('identifier', 'type', 'file_path')] : []
      end
    end
  end
  WoodsMap.send(:remove_const, :Engine) if scenario == 'missing_map'
  public_url = scenario == 'public_url' ? 'https://map.example.test/reviews' : nil
  WoodsMap.configuration = Struct.new(:index_path, :public_url).new(index, public_url)
  fixture_data = { index: index, units: units, inventories: inventories, manifests: manifests, checksums: checksums, scenario: scenario }
  WoodsMap::Repository.fixture = fixture_data
  if scenario == 'wrong_file_owner'
    WoodsMap::Repository.define_method(:file_owners) { |_| [{ 'identifier' => identifier, 'type' => 'service' }] }
  end
  if scenario == 'wrong_unit_path'
    units.last['file_path'] = 'app/views/posts/other.html.erb'
  end

  module Woods
    class PublishedIndex < WoodsMap::Repository
      class << self; attr_accessor :fixture; end
      def self.available_generations(_path)
        case fixture[:scenario]
        when 'pruned_base' then [2]
        when 'unpublished_head' then [1]
        else [1, 2]
        end
      end
      def initialize(_path, generation:); super(generation); end
      def external_dependency_checksum; self.class.fixture.fetch(:checksums).fetch(@number); end
      def close; end
    end
  end
  Woods::PublishedIndex.fixture = fixture_data
  if %w[held_current_lock held_base_lock].include?(scenario)
    # Only this child's disposable fixture is locked; no app/user index is opened.
    number = scenario == 'held_current_lock' ? 2 : 1
    payload = index.join('payloads', "gen-#{number}")
    FileUtils.mkdir_p(payload)
    File.write(payload.join('manifest.json'), JSON.generate(manifests.fetch(number)))
    held_manifest = File.open(payload.join('manifest.json'), File::RDONLY)
    held_manifest.flock(File::LOCK_EX | File::LOCK_NB)
    at_exit { held_manifest.close }
    ENV['WOODS_MAP_IMPACT_TIMEOUT'] = '1'
    if number == 2
      WoodsMap::Repository.define_singleton_method(:open) do |path, &block|
        puts 'REAL_PUBLISHED_INDEX_LOCK_WAIT gen:2'
        real_published_index.open(path, &block)
      end
    else
      Woods::PublishedIndex.define_singleton_method(:new) do |path, generation:|
        puts "REAL_PUBLISHED_INDEX_LOCK_WAIT gen:#{generation}"
        real_published_index.new(path, generation: generation)
      end
    end
  end
  units.first.delete('metadata') if scenario == 'invalid_retained_unit'
  manifests[1]['total_units'] = 50_001 if scenario == 'oversized_index'

  escaped = ->(value) { CGI.escapeHTML(value.to_s) }
  query = { 'from' => 'gen:1', 'to' => 'gen:2', 'focus' => identifier, 'lens' => 'changed' }
  focus_url = "#{public_url || 'http://localhost'}/woods/impact?#{URI.encode_www_form(query)}"
  focus_url += '&token=synthetic-private-token' if scenario == 'focus_token'
  focus_url = focus_url.sub('gen%3A1', 'gen%3A9') if scenario == 'wrong_focus_url'
  unit_path = '/woods/units/view_template/' + identifier.split('/').map { |part| URI.encode_www_form_component(part).gsub('+', '%20') }.join('/')
  unit_href = "#{unit_path}?#{URI.encode_www_form('since' => 'gen:1')}"
  unit_href = unit_href.sub('view_template', 'service') if scenario == 'wrong_typed_link'
  unit_href = unit_href.sub('gen%3A1', 'gen%3A9') if scenario == 'wrong_since_link'
  row_class = scenario == 'missing_focus_mark' ? '' : 'grp focus'
  row = <<~HTML
    <tr id="changed-1" class="#{row_class}" aria-current="true">
      <td class="tg"><button class="tgl" aria-expanded="true">+</button></td>
      <td data-h="unit"><a href="#{escaped.call(unit_href)}">#{escaped.call(identifier)}</a></td>
      <td data-h="type">view template</td><td data-h="status">modified</td>
      <td data-h="facets moved">source</td><td data-h="payload">gen 2</td>
    </tr><tr class="sub open"><td>PRIVATE_TEMPLATE_BODY</td></tr>
  HTML
  row = row.sub('data-h="payload">gen 2', 'data-h="payload">gen 1') if scenario == 'wrong_row_generation'
  row = '' if scenario == 'missing_change_row'
  range_body = <<~HTML
    <html><body><h1>gen 1 → gen 2<span class="sub">retained generation evidence</span></h1>
      <button data-copy-text-value="#{escaped.call(focus_url)}">⎘ copy focus URL</button>
      <table aria-label="Changed units"><tbody>#{row}</tbody></table>
      <p>computed by Woods from gen 1 and gen 2 · map on gen 2</p>
    </body></html>
  HTML
  range_body = '<h1>Impact range</h1><p>Range evidence unavailable</p>' if scenario == 'range_unavailable'
  return_query = { 'from' => 'gen:1', 'to' => 'now', 'focus' => identifier, 'lens' => 'changed' }
  return_link = '/woods/impact?' + URI.encode_www_form(return_query)
  since_mark = if %w[deletion_only wrong_removal_count].include?(scenario)
                 '<div class="row contents row-rm" id="L2"><div class="ln" title="1 line removed after this line since gen 1">2<span class="sr-only">, 1 line removed after it since gen 1</span></div></div>'
               else
                 '<div class="row contents row-chg" id="L2"><div class="ln">2<span class="sr-only">, changed since gen 1</span></div></div>'
               end
  if %w[two_hunks partial_hunks].include?(scenario)
    since_mark += since_mark.sub('L2', 'L4').sub('>2<', '>4<')
  end
  extra = '<div class="row contents row-chg" id="L1"><div class="ln">1<span class="sr-only">, changed since gen 1</span></div></div>'
  since_mark += extra if scenario == 'extra_changed_highlight'
  since_mark += extra.sub('row-chg', 'row-rm').sub('changed since gen 1', '3 lines removed after it since gen 1') if scenario == 'extra_removal_highlight'
  since_mark += '<div class="row contents row-chg" id="L1"><div class="ln">1</div><div class="mg">metadata changed since gen 1</div></div>' if scenario == 'metadata_styling'
  since_mark = since_mark.gsub('1 line removed', '2 lines removed') if scenario == 'wrong_removal_count'
  since_mark = '' if scenario == 'missing_highlight'
  since_mark = since_mark.sub('L2', 'L1') if scenario == 'wrong_highlight_line'
  since_mark = since_mark.sub('since gen 1', 'since gen 9') if scenario == 'wrong_highlight_generation'
  since_body = <<~HTML
    <html><body><h1>#{escaped.call(identifier)}</h1>
      <div class="frame-facts"><div class="banner mod">Modified since gen 1.
        Facets moved: source; Woods' report, gen 1 → gen 2.
        <a href="#{escaped.call(return_link)}">open the report</a></div></div>
      <div class="cvwrap" aria-label="Source of #{escaped.call(identifier)}, as written lens">
        <div class="cv codeview">#{since_mark}<div class="src">PRIVATE_TEMPLATE_BODY</div></div>
      </div></body></html>
  HTML
  since_body = since_body.sub('gen 1 → gen 2', 'gen 1 → gen 3') if scenario == 'mixed_since_head'

  module Rack
    class MockRequest
      class << self; attr_accessor :fixture, :requests; end
      def initialize(application); raise 'wrong Rack app' unless application == :synthetic_application; end
      def get(path, headers)
        raise 'not loopback' unless headers['REMOTE_ADDR'] == '127.0.0.1' && headers['HTTP_HOST'] == 'localhost'
        raise 'wrong auth' unless headers['HTTP_AUTHORIZATION'] == 'Bearer synthetic-private-token'
        self.class.requests << path
        input = self.class.fixture
        uri = URI.parse(path)
        params = URI.decode_www_form(uri.query.to_s).to_h
        status = { 'unauthorized' => 401, 'missing_mount' => 404, 'redirect' => 302 }.fetch(input[:scenario], 200)
        body = if uri.path == '/woods/impact' && params == input[:query]
                 input[:range_body]
               elsif URI::DEFAULT_PARSER.unescape(uri.path).force_encoding('UTF-8') == input[:unit_path] && params == { 'since' => 'gen:1' }
                 input[:since_body]
               else
                 status = 404
                 'unexpected route'
               end
        Struct.new(:status, :body).new(status, body)
      end
    end
  end
  Rack::MockRequest.requests = []
  Rack::MockRequest.fixture = { scenario: scenario, query: query, range_body: range_body, since_body: since_body,
                               unit_path: '/woods/units/view_template/' + identifier }

  ENV['WOODS_MAP_IMPACT_FROM'] = 'gen:1'
  ENV['WOODS_MAP_IMPACT_TO'] = 'gen:2'
  ENV['WOODS_MAP_IMPACT_TEMPLATE'] = template
  ENV['WOODS_MAP_IMPACT_REPORT_ID'] = id
  ENV['WOODS_MAP_IMPACT_MARKDOWN'] = markdown_path.to_s
  case scenario
  when 'invalid_timeout' then ENV['WOODS_MAP_IMPACT_TIMEOUT'] = '0'
  when 'missing_input' then ENV.delete('WOODS_MAP_IMPACT_FROM')
  when 'identical_selectors' then ENV['WOODS_MAP_IMPACT_FROM'] = 'gen:2'
  when 'moving_selector' then ENV['WOODS_MAP_IMPACT_TO'] = 'now'
  when 'sha_selector' then ENV['WOODS_MAP_IMPACT_FROM'] = 'a' * 40
  when 'reverse_range' then ENV['WOODS_MAP_IMPACT_FROM'], ENV['WOODS_MAP_IMPACT_TO'] = 'gen:2', 'gen:1'
  when 'path_traversal' then ENV['WOODS_MAP_IMPACT_TEMPLATE'] = 'app/views/../posts/_card.html.erb'
  when 'absolute_template' then ENV['WOODS_MAP_IMPACT_TEMPLATE'] = '/app/views/posts/_card.html.erb'
  when 'comma_template' then ENV['WOODS_MAP_IMPACT_TEMPLATE'] = 'app/views/posts/_card,other.html.erb'
  when 'bad_report_id' then ENV['WOODS_MAP_IMPACT_REPORT_ID'] = '../report'
  when 'missing_cache' then FileUtils.remove_entry(index)
  end
  if %w[child_deadline child_descendant_deadline].include?(scenario)
    # Trusted fixed child code only. Both parent and descendant resist TERM;
    # inherited output pipes test the helper's KILL even after the leader exits.
    $stdout.sync = true
    trap('TERM', 'IGNORE')
    fork { sleep 30 }
    puts 'deadline child ready'
    exit! 0 if scenario == 'child_descendant_deadline'
    sleep 30
  end
  at_exit do
    if $!.is_a?(SystemExit) && $!.success? && File.basename(smoke) == 'woods_map_impact_smoke.rb'
      raise 'success did not exercise both real routes' unless Rack::MockRequest.requests.size == 2
    end
  end
  load smoke
RUBY

# A failure must reach its intended assertion, rather than merely crashing on a
# missing dependency or an unrelated earlier precondition.
scenarios = {
  'valid' => nil, 'escaped_identifier' => nil, 'public_url' => nil,
  'partial_evidence' => nil, 'deletion_only' => nil, 'two_hunks' => nil, 'metadata_styling' => nil,
  'child_deadline' => 'watchdog', 'child_descendant_deadline' => 'watchdog',
  'witness_to' => nil, 'witness_from' => nil, 'witness_chain' => nil, 'source_unknown' => nil,
  'classification_unknowns' => nil,
  'unknown_missing_context' => 'endpoint', 'unknown_missing_endpoint' => 'endpoint',
  'unknown_invalid_endpoint' => 'endpoint', 'unknown_float_generation' => 'generation',
  'unknown_string_generation' => 'generation', 'unknown_null_generation' => 'generation',
  'unknown_empty_kind' => 'kind', 'unknown_missing_kind' => 'kind',
  'deferred_unknown_missing_feature' => 'not_computed', 'deferred_unknown_bad_feature' => 'not_computed',
  'snapshot_unknown_extra_field' => 'snapshot_binding',
  'classification_unknown_missing_identity' => 'unclassified', 'classification_unknown_empty_keys' => 'unclassified',
  'source_unknown_missing_context' => 'source_unavailable',
  'source_unknown_untyped_with_generation' => 'source_unavailable',
  'source_unknown_with_generation' => 'source_unavailable',
  'source_unknown_missing_identifier' => 'source_unavailable', 'source_unknown_empty_identifier' => 'source_unavailable',
  'source_unknown_empty_type' => 'source_unavailable', 'source_unknown_nonstring_type' => 'source_unavailable',
  'source_unknown_invalid_endpoint' => 'source_unavailable', 'source_unknown_extra_field' => 'source_unavailable',
  'outer_supervisor_timeout' => 'external timeout', 'outer_timeout_during_launch' => 'external timeout',
  'missing_coverage_key' => 'coverage', 'invalid_coverage_value' => 'coverage',
  'missing_focus_unknown' => 'unknown', 'missing_commits_unknown' => 'unknown', 'missing_snapshot_unknown' => 'unknown',
  'partial_hunks' => 'hunks', 'wrong_side_root' => 'root', 'untyped_root' => 'root',
  'empty_edges' => 'edges', 'malformed_edge' => 'edge', 'broken_chain' => 'chain',
  'wrong_witness_target' => 'chain', 'wrong_distance' => 'distance',
  'unknown_missing_generation' => 'generation', 'untyped_source_unknown' => 'source_unavailable',
  'held_current_lock' => 'deadline', 'held_base_lock' => 'deadline', 'invalid_timeout' => 'TIMEOUT',
  'extra_changed_highlight' => 'highlight', 'extra_removal_highlight' => 'highlight',
  'wrong_removal_count' => 'highlight', 'deletion_at_start' => 'anchor',
  'missing_input' => 'WOODS_MAP_IMPACT_FROM', 'identical_selectors' => 'distinct',
  'moving_selector' => 'gen:N', 'sha_selector' => 'gen:N', 'reverse_range' => 'older',
  'path_traversal' => 'app-relative', 'absolute_template' => 'app-relative', 'comma_template' => 'comma',
  'bad_report_id' => 'REPORT_ID', 'missing_markdown' => 'Markdown', 'missing_map' => 'mounted',
  'missing_cache' => 'cache', 'pruned_base' => 'retained', 'unpublished_head' => 'retained',
  'head_not_current' => 'current', 'wrong_file_owner' => 'typed owner', 'wrong_unit_path' => 'file_path',
  'invalid_retained_unit' => 'retained template', 'oversized_index' => 'unit limit',
  'missing_saved_report' => 'saved report', 'bad_digest' => 'saved report',
  'wrong_schema' => 'saved report', 'malformed_json' => 'saved report',
  'missing_array' => 'templates', 'malformed_array' => 'affected', 'malformed_change_record' => 'Malformed changed',
  'wrong_endpoint' => 'generation', 'wrong_selector' => 'selector', 'wrong_checksum' => 'manifest',
  'wrong_git_sha' => 'git_sha', 'missing_change' => 'expected template', 'typed_collision' => 'expected template',
  'duplicate_change' => 'duplicate', 'metadata_only' => 'source',
  'missing_hunks' => 'source_changes', 'truncated_hunks' => 'complete', 'bad_hunk' => 'hunk', 'float_hunk' => 'hunk',
  'wrong_source_stats' => 'diff_stats', 'mixed_generation' => 'generation', 'mixed_witness' => 'witness',
  'mixed_unknown_generation' => 'generation',
  'wrong_markdown' => 'Markdown', 'stale_markdown' => 'Markdown',
  'range_unavailable' => 'range', 'unauthorized' => 'HTTP 401', 'missing_mount' => 'HTTP 404', 'redirect' => 'HTTP 302',
  'wrong_focus_url' => 'focus URL', 'focus_token' => 'focus URL',
  'wrong_typed_link' => 'typed template', 'wrong_since_link' => 'typed template',
  'wrong_row_generation' => 'payload', 'missing_focus_mark' => 'focused', 'missing_change_row' => 'typed template',
  'missing_highlight' => 'highlight', 'wrong_highlight_line' => 'highlight',
  'wrong_highlight_generation' => 'highlight', 'mixed_since_head' => 'since range'
}
if options[:case]
  abort 'Unknown self-test case' unless scenarios.key?(options[:case])
  scenarios = scenarios.slice(options[:case])
end
original_environment = ENV.to_h
scenarios.each do |name, diagnostic|
  Dir.mktmpdir('w38-') do |root|
    if name.start_with?('outer_')
      termination_case(name, options, root)
      next
    end
    fixture_path = File.join(root, 'impact_fixture.rb')
    File.write(fixture_path, fixture)
    # Fixed adapter code runs as a file, without evaluating fixture text.
    # Independent child deadlines also clean up inherited output pipes.
    result = ImpactSmokeChildren.capture(
      command: [RbConfig.ruby, '-I', woods_lib, fixture_path, options.fetch(:smoke), name, root],
      timeout: name.start_with?('child_') ? 2 : 8,
      env: { 'WOODS_MAP_TOKEN' => nil, 'IMPACT_SELF_TEST_INHERITED' => 'retained', 'WOODS_MAP_IMPACT_TIMEOUT' => nil }
    )
    exit(128 + Signal.list.fetch(result.signal)) if result.signal
    stdout = result.stdout_lines.join("\n")
    output = stdout + result.stderr_text
    raise "#{name}: leaked private fixture data" if output.include?('synthetic-private-token') || output.include?('PRIVATE_TEMPLATE_BODY')
    if name.start_with?('child_')
      killed = name == 'child_deadline' ? result.status&.termsig == Signal.list.fetch('KILL') : result.status&.success?
      raise "#{name}: process-group deadline/cleanup contract failed" unless result.timed_out && killed && stdout.include?('deadline child ready')
      puts "PASS #{name} process group terminated by bounded watchdog cleanup"
      next
    end
    raise "#{name}: self-test child deadline exceeded (process group terminated); runner did not finish\n#{stdout}" if result.timed_out
    status = result.status
    expected_status = diagnostic ? 1 : 0
    valid = status.exitstatus == expected_status &&
            (diagnostic ? stdout.include?('FAIL') && stdout.include?(diagnostic) : stdout.include?('8/8 steps passed'))
    raise "#{name}: expected exit #{expected_status}#{" and #{diagnostic.inspect}" if diagnostic}, got #{status.exitstatus}\n#{output}" unless valid
    raise "#{name}: successful skip" if output.match?(/\bSKIP\b/)

    puts "PASS #{name} #{diagnostic ? 'rejected at intended contract' : 'accepted'}"
  end
end
raise 'self-test changed the caller environment' unless ENV.to_h == original_environment

puts "#{scenarios.size}/#{scenarios.size} process cases passed (synthetic adapters; live acceptance still required)"
