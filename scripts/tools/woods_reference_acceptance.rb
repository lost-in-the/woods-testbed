# frozen_string_literal: true

# Outside Rails, in the disposable app created by bin/woods_reference_acceptance.rb.
require 'bundler/setup'
require 'digest'
require 'fileutils'
require 'json'
require 'timeout'
require 'woods'
require_relative '../support/mcp_session'
require_relative '../support/reference_snapshot'

class ReferenceAcceptance
  LEAF = 'app/models/reference_poro.rb'
  CONCERN = 'app/models/concerns/reference_concern.rb'
  ARRIVAL = 'app/models/reference_later_target.rb'
  MODULE_INCLUDER = 'app/models/reference_module_includer.rb'
  OWNERSHIP_MODULE = 'app/models/reference_ownership.rb'

  def initialize
    @report = ENV.fetch('WOODS_ACCEPTANCE_REPORT_DIR')
    @index = ENV.fetch('WOODS_OUTPUT')
    @corpus_dir = File.expand_path('../fixtures/source_references', __dir__)
    @corpus = JSON.parse(File.read(File.join(@corpus_dir, 'corpus.json')))
    @checks = []
    @operations = []
    @equivalences = []
    @sequence = 0
    FileUtils.mkdir_p(@report)
  end

  def run
    identity!
    %w[app lib].each { |name| FileUtils.cp_r(File.join(@corpus_dir, name, '.'), name) }
    check('fresh isolated database prepares') { command(['bin/rails', 'db:prepare']) }
    check('candidate provides the source-reference integration') do
      require 'woods/source_references/pass'
      require 'woods/source_references/cache'
      raise 'source-reference writer not integrated' unless File.read(File.join(Gem.loaded_specs.fetch('woods').full_gem_path, 'lib/woods/extractor.rb')).include?('enrich_source_references_full')
    end
    check('full extraction establishes a reference baseline') { operation('full') }
    @session = McpSession.new(command: [Gem.ruby, '-r', '/harness/support/reference_mcp_format.rb',
                                      Gem.bin_path('woods', 'woods-mcp'), @index], timeout: 30)
    @reader_pid = @session.pid
    check('labelled caller families have exact forward and reverse code references') do
      @corpus.fetch('positive').each { |edge| assert_edge(*edge, present: true) }
      @corpus.fetch('negative').each do |edge|
        # A missing target is not a valid string/comment/shadowing control.
        lookup(edge[2], edge[3]) unless @corpus.fetch('initially_absent_targets').include?(edge[3])
        assert_edge(*edge, present: false)
      end
    end
    module_discovery!
    unless ENV['WOODS_REFERENCE_FAILURE_ONLY'] == '1'
      equivalence!('deterministic repeated full extraction', strict: true)
      baseline_ordering! if ENV['WOODS_REFERENCE_BASELINE_GEMFILE']
      mutation_cases!
      module_ownership_cases!
    end
    failure_case!
    check('final index validates') { command(['bin/rails', 'woods:validate']) }
    performance! if ENV['WOODS_REFERENCE_BASELINE_GEMFILE']
    @passed = true
  rescue StandardError => error
    @error = "#{error.class}: #{error.message}"
    warn @error
  ensure
    begin
      @session&.close
    rescue StandardError => error
      @passed = false
      @error = [@error, "MCP cleanup: #{error.message}"].compact.join("\n")
    end
    report = { status: @passed ? 'PASS' : 'FAIL', identity: @identity, checks: @checks,
               check_selection: ENV['WOODS_REFERENCE_FAILURE_ONLY'] == '1' ? 'failure_only' : 'full',
               operations: @operations, equivalences: @equivalences, reader_pid: @reader_pid, error: @error,
               corpus: @corpus, performance: @performance || { status: 'NOT_RUN', reason: 'no baseline supplied' },
               coverage: 'synthetic Rails 8 Canopy corpus; source references, not execution coverage' }
    File.write(File.join(@report, 'acceptance.json'), JSON.pretty_generate(report) + "\n")
    puts JSON.generate(status: report[:status], checks: @checks.size, report: File.join(@report, 'acceptance.json'))
    return @passed ? 0 : 1
  end

  private

  def identity!
    spec = Gem.loaded_specs.fetch('woods')
    mode = ENV.fetch('WOODS_ACCEPTANCE_MODE')
    path = File.realpath(spec.full_gem_path)
    loaded = File.realpath(Woods.method(:configuration).source_location.first)
    source = Bundler.load.specs.find { |item| item.name == 'woods' }.source.class.name
    raise 'Woods loaded outside activated gem' unless loaded.start_with?(path + '/')
    if mode == 'artifact'
      expected = ENV.fetch('WOODS_ACCEPTANCE_GEM_SHA256')
      raise 'artifact resolved from source' unless source == 'Bundler::Source::Rubygems' && !path.start_with?('/woods-gem')
      raise 'artifact bytes changed' unless Digest::SHA256.file(ENV.fetch('WOODS_ACCEPTANCE_GEM_FILE')).hexdigest == expected
      raise 'installed package differs' unless File.file?(spec.cache_file) && Digest::SHA256.file(spec.cache_file).hexdigest == expected
      raise 'checkout load path leaked' if $LOAD_PATH.any? { |entry| entry.start_with?('/woods-gem') }
    else
      raise "wrong source mount: #{path} (#{source}; Gemfile #{ENV['BUNDLE_GEMFILE']})" unless mode == 'source' && path == '/woods-gem' && source == 'Bundler::Source::Path'
    end
    paths = Bundler.settings.locations('path')
    raise 'bundle path must be isolated in the environment' unless paths[:env] == ENV.fetch('BUNDLE_PATH') && !paths.key?(:local)
    if ENV['WOODS_REFERENCE_BASELINE_GEMFILE']
      dependency_sets = [ENV.fetch('BUNDLE_GEMFILE'), ENV.fetch('WOODS_REFERENCE_BASELINE_GEMFILE')].map do |gemfile|
        Bundler::LockfileParser.new(File.read("#{gemfile}.lock")).specs.reject { |entry| entry.name == 'woods' }
          .map { |entry| [entry.name, entry.version.to_s, entry.platform.to_s] }.sort
      end
      raise 'baseline/candidate non-Woods dependencies differ' unless dependency_sets.first == dependency_sets.last
    end
    @identity = { mode: mode, revision: ENV.fetch('WOODS_ACCEPTANCE_REVISION'), woods_version: Woods::VERSION,
                  loaded_path: path, loaded_source: loaded, bundler_source: source, ruby: RUBY_VERSION,
                  rails: Gem.loaded_specs.fetch('railties').version.to_s, bundle_path: ENV.fetch('BUNDLE_PATH'),
                  corpus_sha256: Digest::SHA256.file(File.join(@corpus_dir, 'corpus.json')).hexdigest,
                  artifact_sha256: ENV['WOODS_ACCEPTANCE_GEM_SHA256'] }
    @identity[:matched_dependency_versions] = dependency_sets.first if dependency_sets
    puts JSON.generate(@identity)
  end

  def mutation_cases!
    original = File.binread(LEAF)
    check('held-open reader observes caller edit') do
      File.write(LEAF, original.sub('ReferenceTarget.generate', 'ReferenceAlternateTarget.generate'))
      operation('incremental', paths: [LEAF])
      assert_edge('poro', 'ReferencePoro', 'poro', 'ReferenceTarget', present: false)
      assert_edge('poro', 'ReferencePoro', 'poro', 'ReferenceAlternateTarget', present: true)
    end
    equivalence!('caller edit agrees with a fresh full extraction')
    check('targeted refresh removes a reference') do
      File.write(LEAF, original.sub('ReferenceTarget.generate', ':removed'))
      operation('refresh', types: ['poros'])
      assert_edge('poro', 'ReferencePoro', 'poro', 'ReferenceAlternateTarget', present: false)
      assert_edge('poro', 'ReferencePoro', 'poro', 'ReferenceTarget', present: false)
    end
    equivalence!('reference removal agrees with full extraction')
    renamed = LEAF.sub('reference_poro', 'reference_renamed_poro')
    check('renamed caller replaces its old typed identity') do
      File.write(renamed, original.sub('ReferencePoro', 'ReferenceRenamedPoro'))
      File.unlink(LEAF)
      operation('incremental', paths: [LEAF, renamed])
      raise 'renamed caller survived under old identity' if units.any? { |unit| unit['identifier'] == 'ReferencePoro' }
      assert_missing('poro', 'ReferencePoro')
      assert_edge('poro', 'ReferenceRenamedPoro', 'poro', 'ReferenceTarget', present: true)
    end
    equivalence!('caller rename agrees with full extraction')
    check('caller restoration withdraws its renamed identity') do
      File.unlink(renamed)
      File.binwrite(LEAF, original)
      operation('incremental', paths: [renamed, LEAF])
      assert_missing('poro', 'ReferenceRenamedPoro')
    end
    equivalence!('caller restoration agrees with full extraction')
    check('target arrival updates an unchanged caller through the same MCP connection') do
      @arrival_before = lookup('poro', 'ReferenceArrivalCaller')
      File.write(ARRIVAL, "class ReferenceLaterTarget\n  def self.generate\n    raise 'must not execute'\n  end\nend\n")
      operation('incremental', paths: [ARRIVAL])
      assert_edge('poro', 'ReferenceArrivalCaller', 'poro', 'ReferenceLaterTarget', present: true)
      after = lookup('poro', 'ReferenceArrivalCaller')
      raise 'reference-only rewrite refreshed caller metadata' unless after.except('dependencies') == @arrival_before.except('dependencies')
    end
    equivalence!('target arrival agrees with full extraction')
    check('target deletion withdraws forward and reverse references') do
      File.unlink(ARRIVAL)
      operation('incremental', paths: [ARRIVAL])
      assert_edge('poro', 'ReferenceArrivalCaller', 'poro', 'ReferenceLaterTarget', present: false)
      raise 'deleted target survived' if units.any? { |unit| unit['identifier'] == 'ReferenceLaterTarget' }
      assert_missing('poro', 'ReferenceLaterTarget')
    end
    equivalence!('target deletion agrees with full extraction')
    check('shared concern edit refreshes its source reference') do
      source = File.binread(CONCERN)
      File.write(CONCERN, source.sub('ReferenceTarget.generate', 'ReferenceAlternateTarget.generate'))
      operation('incremental', paths: [CONCERN])
      assert_edge('concern', 'ReferenceConcern', 'poro', 'ReferenceTarget', present: false)
      assert_edge('concern', 'ReferenceConcern', 'poro', 'ReferenceAlternateTarget', present: true)
    end
    equivalence!('concern edit agrees with full extraction')
  end

  def failure_case!
    check('failed enrichment preserves the last graph, cache, and live reader') do
      marker = File.binread(File.join(@index, 'generation.json'))
      before = ReferenceSnapshot.fingerprint(@index)
      reader_before = lookup('poro', 'ReferencePoro')
      operation('incremental', paths: [LEAF], fault_path: LEAF, expected_failure: true)
      raise 'failed run advanced generation' unless File.binread(File.join(@index, 'generation.json')) == marker
      raise 'failed run mutated published payload bytes/tree' unless ReferenceSnapshot.fingerprint(@index) == before
      raise 'held reader lost previous unit' unless lookup('poro', 'ReferencePoro') == reader_before
    end
  end

  def module_discovery!
    check('standalone singleton module exposes its own method and inbound/outbound references') do
      encryption = lookup('poro', 'ReferenceEncryption')
      raise 'missing module metadata' unless encryption.dig('metadata', 'ruby_kind') == 'module'
      raise 'singleton method not recorded' unless encryption.dig('metadata', 'class_methods').include?('encrypt')
      assert_edge('poro', 'ReferenceModuleCaller', 'poro', 'ReferenceEncryption', present: true)
      assert_edge('poro', 'ReferenceEncryption', 'poro', 'ReferenceTarget', present: true)
    end
    check('namespace-only module stays absent while its child class is indexed') do
      assert_missing('poro', 'ReferenceNamespaceOnly')
      assert_missing('concern', 'ReferenceNamespaceOnly')
      lookup('poro', 'ReferenceNamespaceOnly::Child')
      raise 'namespace-only module gained a graph node' if ReferenceSnapshot.json(@index, 'dependency_graph.json').fetch('nodes').key?('ReferenceNamespaceOnly')
      raise 'namespace-only module gained a caller edge' if lookup('poro', 'ReferenceModuleCaller').fetch('dependencies').any? { |edge| edge['target'] == 'ReferenceNamespaceOnly' }
    end
    check('unincluded callable module initially belongs to PORO extraction') { assert_module_owner('poro') }
  end

  def module_ownership_cases!
    original = File.binread(MODULE_INCLUDER)
    module_digest = Digest::SHA256.file(OWNERSHIP_MODULE).hexdigest
    check('includer-only edit migrates a module from PORO to concern through the held reader') do
      File.binwrite(MODULE_INCLUDER, original.sub('# ownership inclusion point', 'include ReferenceOwnership'))
      operation('incremental', paths: [MODULE_INCLUDER])
      raise 'ownership fixture module changed' unless Digest::SHA256.file(OWNERSHIP_MODULE).hexdigest == module_digest
      assert_module_owner('concern')
      # The module owns its body reference; including it does not copy that edge.
      assert_edge('model', 'ReferenceModuleIncluder', 'poro', 'ReferenceTarget', present: false)
    end
    equivalence!('includer-only PORO to concern migration agrees with full extraction')
    check('includer-only removal restores standalone ownership through the held reader') do
      File.binwrite(MODULE_INCLUDER, original)
      operation('incremental', paths: [MODULE_INCLUDER])
      raise 'ownership fixture module changed' unless Digest::SHA256.file(OWNERSHIP_MODULE).hexdigest == module_digest
      assert_module_owner('poro')
    end
    equivalence!('includer-only concern to PORO migration agrees with full extraction')
  end

  def assert_module_owner(type)
    other = type == 'poro' ? 'concern' : 'poro'
    unit = lookup(type, 'ReferenceOwnership')
    raise 'restored module lost module metadata' if type == 'poro' && unit.dig('metadata', 'ruby_kind') != 'module'
    assert_missing(other, 'ReferenceOwnership')
    identities = units.select { |entry| entry['identifier'] == 'ReferenceOwnership' }.map { |entry| entry['type'] }
    raise "duplicate or wrong module owners: #{identities.inspect}" unless identities == [type]
    assert_edge(type, 'ReferenceOwnership', 'poro', 'ReferenceTarget', present: true)
    assert_edge('poro', 'ReferenceModuleCaller', type, 'ReferenceOwnership', present: true)
    caller = lookup('poro', 'ReferenceModuleCaller')
    raise 'old typed module edge survived' if caller.fetch('dependencies').any? { |edge| edge['target'] == 'ReferenceOwnership' && edge['type'] == other }
    raise 'held MCP reader was replaced' unless @session.pid == @reader_pid
  end

  def performance!
    repetitions = Integer(ENV.fetch('WOODS_REFERENCE_PERF_REPS', '5'))
    raise 'performance comparison requires at least five pairs' if repetitions < 5
    @performance = { status: 'RUNNING', baseline_revision: ENV.fetch('WOODS_REFERENCE_BASELINE_REVISION'),
                     repetitions: repetitions, samples: [],
                     caveats: ['Synthetic Canopy fixture, not a large-host performance claim.',
                               'Extraction timings exclude process/Rails boot; peak RSS includes both.',
                               'A median overhead above 10% is a review trigger, not a failing threshold.'] }
    check('alternating baseline/candidate full, leaf, and shared-concern measurements complete') do
      %w[full leaf concern].each do |scenario|
        repetitions.times do |trial|
          order = trial.even? ? %w[baseline candidate] : %w[candidate baseline]
          order.each do |variant|
            @performance[:samples] << performance_sample(scenario, variant, trial)
          end
        end
      end
      @performance[:summary] = %w[full leaf concern].to_h do |scenario|
        samples = @performance[:samples].select { |sample| sample[:scenario] == scenario }
        medians = %w[baseline candidate].to_h do |variant|
          values = samples.select { |sample| sample[:variant] == variant }.map { |sample| sample[:measurement].fetch('wall_ms') }.sort
          middle = values.length / 2
          median = values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
          [variant, median]
        end
        overhead = 100.0 * (medians.fetch('candidate') / medians.fetch('baseline') - 1)
        [scenario, { median_ms: medians, overhead_percent: overhead.round(2), review_required: overhead > 10 }]
      end
      @performance[:status] = 'MEASURED'
    end
  end

  def baseline_ordering!
    check('baseline control records independent full/full presentation differences') do
      indexes = ['/scratch/baseline-ordering-1', '/scratch/baseline-ordering-2']
      FileUtils.rm_rf('tmp/cache/bootsnap')
      indexes.each { |index| operation('full', index: index, baseline: true) }
      differences = ReferenceSnapshot.differences(*indexes, semantic: false, cache_required: false)
      a, b = indexes.map { |index| ReferenceSnapshot.read(index, semantic: false, cache_required: false) }
      controller_order = differences.filter_map do |entry|
        next unless entry.fetch(:path).start_with?('units/controllers/')

        name = entry.fetch(:path).delete_prefix('units/')
        left, right = [a, b].map do |snapshot|
          unit = Marshal.load(Marshal.dump(snapshot.fetch('units').fetch(name)))
          unit.fetch('metadata')['actions']&.sort!
          unit['chunks']&.sort_by! { |chunk| chunk.fetch('identifier') }
          unit
        end
        name if left == right
      end
      @equivalences << { name: 'pre-expansion baseline full/full control',
                         baseline_revision: ENV.fetch('WOODS_REFERENCE_BASELINE_REVISION'),
                         strict_whole_index_differences: differences,
                         confirmed_controller_action_order_only: controller_order }
      original = File.binread(LEAF)
      File.binwrite(LEAF, original + "\n# baseline incremental ordering control\n")
      operation('incremental', index: indexes.first, baseline: true, paths: [LEAF])
      operation('full', index: indexes.last, baseline: true)
      @equivalences << { name: 'pre-expansion baseline incremental/full control',
                         baseline_revision: ENV.fetch('WOODS_REFERENCE_BASELINE_REVISION'),
                         strict_whole_index_differences: ReferenceSnapshot.differences(*indexes, semantic: false, cache_required: false),
                         semantic_differences: ReferenceSnapshot.differences(*indexes, cache_required: false, scope: :fixture) }
    ensure
      File.binwrite(LEAF, original) if original
      indexes&.each { |index| FileUtils.rm_rf(index) }
    end
  end

  def performance_sample(scenario, variant, trial)
    index = "/scratch/perf-#{scenario}-#{variant}-#{trial}"
    baseline = variant == 'baseline'
    path = scenario == 'concern' ? CONCERN : LEAF
    original = File.binread(path)
    if scenario == 'full'
      measurement = operation('full', index: index, baseline: baseline)
    else
      operation('full', index: index, baseline: baseline)
      File.binwrite(path, original + "\n# source-reference #{scenario} trial #{trial}\n")
      measurement = operation('incremental', index: index, baseline: baseline, paths: [path])
    end
    { scenario: scenario, variant: variant, trial: trial + 1, measurement: measurement }
  ensure
    File.binwrite(path, original) if original
    FileUtils.rm_rf(index) if index
  end

  def assert_edge(type, owner, target_type, target, present:)
    edge = { 'type' => target_type, 'target' => target, 'via' => 'code_reference' }
    found = lookup(type, owner).fetch('dependencies').include?(edge)
    raise "#{type}:#{owner} → #{target_type}:#{target}: expected #{present}, got #{found}" unless found == present
    graph = ReferenceSnapshot.json(@index, 'dependency_graph.json')
    reverse = graph.fetch('reverse', {}).fetch(target, []).include?(owner)
    via = graph.fetch('reverse_via', {}).fetch(target, []).any? do |record|
      record['source'] == owner && record['source_type'] == type && record['via'] == 'code_reference'
    end
    raise "reverse_via disagrees for #{owner} → #{target}" unless via == present
    raise "missing reverse relationship #{owner} → #{target}" if present && !reverse
    [['dependencies', owner, target], ['dependents', target, owner]].each do |tool, root, peer|
      response = @session.call_tool(tool, { identifier: root, depth: 1, via: 'code_reference', limit: 1000 })
      data = response.fetch('structuredContent').fetch('data')
      raise "#{tool} was truncated" if data['partial'] || data['has_more']
      observed = data.fetch('nodes').key?(peer)
      raise "held MCP #{tool} disagrees for #{root} → #{peer}" unless observed == present
    end
    return unless present

    dependents = lookup(target_type, target).fetch('dependents')
    raise "serialized dependents missing #{owner}" unless dependents.include?('type' => type, 'identifier' => owner)
  end

  def lookup(type, identifier)
    result = @session.call_tool('lookup', { identifier: identifier, type: type })
    data = result.fetch('structuredContent').fetch('data')
    raise "lookup returned wrong identity #{data.inspect[0, 300]}" unless data['identifier'] == identifier && data['type'] == type
    data
  end

  def assert_missing(type, identifier)
    result = @session.request('tools/call', { name: 'lookup', arguments: { identifier: identifier, type: type } })
    raise "MCP retained deleted #{type}:#{identifier}" unless result['isError'] && result.dig('_meta', 'error_code') == 'not_found'
  end

  def units
    ReferenceSnapshot.read(@index).fetch('units').values
  end

  def equivalence!(name, strict: false)
    check(name) do
      oracle = "/scratch/oracle-#{@sequence}"
      operation('full', index: oracle)
      differences = ReferenceSnapshot.differences(@index, oracle, scope: :fixture)
      raw = ReferenceSnapshot.differences(@index, oracle, semantic: false, scope: :fixture)
      whole = ReferenceSnapshot.differences(@index, oracle, semantic: false)
      @equivalences << { name: name, strict: strict, semantic_differences: differences,
                         strict_differences: raw,
                         strict_whole_index_differences: whole,
                         tolerated_difference_counts: (raw - differences).flat_map do |entry|
                           Array(entry[:fields] || entry[:path]).map { |field| "#{entry[:path].split('/').first}/#{field}" }
                         end.tally }
      failure = strict ? raw : differences
      unless failure.empty?
        File.write(File.join(@report, "#{@sequence}-equivalence-diff.json"), JSON.pretty_generate(@equivalences.last) + "\n")
        raise "incremental/full differences: #{failure.first(2).inspect}"
      end
    ensure
      FileUtils.rm_rf(oracle) if oracle
    end
  end

  def operation(kind, index: @index, expected_failure: false, baseline: false, **options)
    report = File.join(@report, format('%03d-operation.json', @sequence + 1))
    args = options.merge(operation: kind, index: index, report: report)
    env = { 'WOODS_REFERENCE_OPERATION' => JSON.generate(args), 'WOODS_OUTPUT' => index }
    if baseline
      env.merge!('BUNDLE_GEMFILE' => ENV.fetch('WOODS_REFERENCE_BASELINE_GEMFILE'),
                 'BUNDLE_APP_CONFIG' => '/app/.bundle-baseline',
                 'WOODS_REFERENCE_EXPECTED_PATH' => '/woods-baseline')
    end
    status = command(['bin/rails', 'runner', '/harness/support/reference_operation.rb'], env: env,
                     allow_failure: expected_failure)
    result = JSON.parse(File.read(report))
    raise 'failure injection unexpectedly succeeded' if expected_failure && status.success?
    raise 'operation did not record expected status' unless result['status'] == (expected_failure ? 'FAIL' : 'PASS')
    @operations << result
    result
  end

  def check(name)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    @checks << { name: name, status: 'PASS', seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3) }
    puts "PASS #{name}"
  rescue StandardError => error
    @checks << { name: name, status: 'FAIL', error: "#{error.class}: #{error.message}" }
    raise
  end

  def command(args, env: {}, allow_failure: false)
    @sequence += 1
    log = File.join(@report, format('%03d-command.log', @sequence))
    File.open(log, 'w') do |output|
      output.puts(args.inspect)
      pid = Process.spawn(env, *args, out: output, err: [:child, :out], pgroup: true)
      _, status = Timeout.timeout(180) { Process.wait2(pid) }
      raise "command failed (#{status.exitstatus}): #{args.inspect}; see #{log}" unless status.success? || allow_failure
      status
    ensure
      if pid
        Process.kill('KILL', -pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
      end
    end
  end
end

exit ReferenceAcceptance.new.run
