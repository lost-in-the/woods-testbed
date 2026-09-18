# frozen_string_literal: true
# Copy source into a disposable app; never modify the interactive working tree.
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'woods/mcp/index_reader'
require_relative '../support/source_provenance'
begin
  require 'woods/source_inputs/manifest'
  source_provenance_supported = true
rescue LoadError
  source_provenance_supported = false
end
raise 'Canopy required' unless Rails.root.join('functional_contract.yml').file?
Dir.mktmpdir('canopy-incremental-') do |scratch|
  %w[app config lib spec bin Gemfile Gemfile.lock Rakefile config.ru].each do |name|
    source = Rails.root.join(name)
    FileUtils.cp_r(source, scratch) if source.exist?
  end
  FileUtils.mkdir_p(File.join(scratch, 'db'))
  FileUtils.cp(Rails.root.join('db/schema.rb'), File.join(scratch, 'db/schema.rb'))
  output = File.join(scratch, 'tmp/woods')
  database = File.expand_path(ActiveRecord::Base.connection_db_config.database, Rails.root)
  env = { 'BUNDLE_GEMFILE' => File.join(scratch, 'Gemfile'), 'DATABASE_URL' => "sqlite3:#{database}", 'WOODS_OUTPUT' => output }
  run = lambda do |task, changed = nil|
    log, status = Open3.capture2e(env.merge('CHANGED_FILES' => changed), 'bundle', 'exec', 'ruby', 'bin/rails', task, chdir: scratch)
    raise "#{task} failed: #{log.lines.last(15).join}" unless status.success?
  end
  semantic = lambda do
    reader = Woods::MCP::IndexReader.new(output)
    reader.list_units.each_with_object({}) do |entry, result|
      unit = reader.find_unit(entry['identifier'])
      next unless unit && %w[model poro concern].include?(unit['type'])
      result[[unit['type'], unit['identifier']]] = [unit['source_code'], unit['metadata'], unit['dependencies']]
    end
  end
  run.call('woods:extract')
  baseline = semantic.call
  source_check = lambda do |history = {}|
    SourceProvenance.read(output, root: scratch, history: history, required: source_provenance_supported)
  end
  baseline_source = source_check.call
  if baseline_source && baseline_source['boot_verified'] != false
    raise 'ordinary post-boot extraction unexpectedly claims a fresh launcher boundary'
  end
  path = 'app/models/concerns/archivable.rb'
  full_path = File.join(scratch, path)
  original = File.read(full_path)
  File.write(full_path, original.sub(/\nend\s*\z/, "\n  def canopy_incremental_probe\n    :present\n  end\nend\n"))
  run.call('woods:incremental', path)
  incremental = semantic.call
  incremental_source = source_check.call(path => { 'baseline' => original })
  if incremental_source && !incremental_source['unverified_scopes'].include?('runtime_consumption')
    raise 'partial runtime extraction lost its unverified consumer qualification'
  end
  %w[Article Comment Billing::Invoice].each do |identifier|
    raise "Concern not refreshed for #{identifier}" unless incremental.fetch(['model', identifier]).first.include?('canopy_incremental_probe')
  end
  raise 'Unrelated billing plan changed' unless incremental.fetch(['model', 'Billing::Plan']) == baseline.fetch(['model', 'Billing::Plan'])
  run.call('woods:clean')
  run.call('woods:extract')
  raise 'Concern incremental differs from full extraction' unless semantic.call == incremental
  full_source = source_check.call
  if full_source
    raise 'full source coverage remains partial' unless full_source['unverified_scopes'].empty?
    # Ordinary task runs cannot advance the runtime boot scope. Everything else
    # must have consumed current bytes; retain that difference explicitly.
    incremental_source.fetch('scopes').each do |scope, paths|
      paths.each do |source_path, version|
        next if version == 'current'
        unless scope == 'runtime' && source_path == path && version == 'retained:baseline'
          raise "unexpected retained source consumer #{scope}: #{source_path}"
        end
      end
    end
    unless full_source.fetch('scopes').values.all? { |paths| paths.values.all? { |version| version == 'current' } }
      raise 'full source identity failed content verification'
    end
  end
  File.write(full_path, original)
  run.call('woods:incremental', path)
  source_check.call(path => { 'modified' => original.sub(/\nend\s*\z/, "\n  def canopy_incremental_probe\n    :present\n  end\nend\n") })
  raise 'Concern removal differs from baseline' unless semantic.call == baseline
  probe_path = 'app/models/canopy_probe.rb'
  File.write(File.join(scratch, probe_path), "class CanopyProbe\n  def call\n    :hello\n  end\nend\n")
  run.call('woods:incremental', probe_path)
  raise 'Added PORO absent' unless semantic.call.key?(['poro', 'CanopyProbe'])
  FileUtils.rm_f(File.join(scratch, probe_path))
  run.call('woods:incremental', probe_path)
  raise 'Deleted PORO survived' if semantic.call.key?(['poro', 'CanopyProbe'])
  run.call('woods:validate')
  raise 'Final incremental differs from baseline' unless semantic.call == baseline
  if source_provenance_supported
    # Whole-app event scanning must not bless an omitted dirty service consumer.
    omitted = 'app/services/provenance_omitted.rb'
    omitted_path = File.join(scratch, omitted)
    FileUtils.mkdir_p(File.dirname(omitted_path))
    before = "class ProvenanceOmitted; def call; :before; end; end\n"
    File.write(omitted_path, before)
    run.call('woods:extract')
    File.write(omitted_path, before.sub(':before', ':after'))
    run.call('woods:refresh[events]')
    source = source_check.call(omitted => { 'baseline' => before })
    raise 'omitted service was silently certified' unless source.dig('scopes', 'file:services', omitted) == 'retained:baseline'
    raise 'event consumer did not advance' unless source.dig('scopes', 'whole:events', omitted) == 'current'
  end
end
puts 'PASS concern fan-out, unrelated model stability, full equivalence, PORO mutations and source-consumer provenance'
