# frozen_string_literal: true
# Copy source into a disposable app; never modify the interactive working tree.
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'digest'
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
    marker_path = File.join(output, 'generation.json')
    pointer = File.binread(marker_path)
    relative_payload = JSON.parse(pointer).fetch('payload')
    raise 'invalid payload path' unless SourceProvenance.safe_path?(relative_payload)
    payload = File.join(output, relative_payload)
    raise 'payload escapes index' unless File.realpath(payload).start_with?("#{File.realpath(output)}/")
    reference_baseline = File.file?(File.join(payload, 'source_references.json'))
    payload_snapshot = lambda do
      Dir.glob(File.join(payload, '**', '*'), File::FNM_DOTMATCH).sort.each_with_object({}) do |entry, tree|
        next if %w[. ..].include?(File.basename(entry))
        stat = File.lstat(entry)
        contents = if stat.symlink?
                     File.readlink(entry)
                   elsif stat.file?
                     Digest::SHA256.file(entry).hexdigest
                   elsif stat.directory?
                     nil
                   else
                     raise "unexpected payload file type: #{entry}"
                   end
        tree[entry.delete_prefix("#{payload}/")] = [stat.ftype, stat.mode, contents]
      end
    end
    prior_payload = payload_snapshot.call if reference_baseline
    prior_service = Woods::MCP::IndexReader.new(output).find_unit('ProvenanceOmitted', type: 'service') if reference_baseline
    File.write(omitted_path, before.sub(':before', ':after'))
    if reference_baseline
      raise 'baseline service is unreadable' unless prior_service && prior_service.fetch('source_code').include?(':before')
      log, status = Open3.capture2e(env.merge('CHANGED_FILES' => nil), 'bundle', 'exec', 'ruby', 'bin/rails', 'woods:refresh[events]', chdir: scratch)
      unless !status.success? && log.include?('Source-reference baseline needs a full extraction') && log.include?(omitted)
        raise "omitted Ruby source did not produce the expected full-baseline refusal: #{log.lines.last(15).join}"
      end
      raise 'refused refresh changed the generation pointer' unless File.binread(marker_path) == pointer
      raise 'refused refresh changed the active payload' unless payload_snapshot.call == prior_payload
      retained_service = Woods::MCP::IndexReader.new(output).find_unit('ProvenanceOmitted', type: 'service')
      raise 'refused refresh lost the readable old service' unless retained_service == prior_service

      run.call('woods:extract')
      run.call('woods:validate')
      current_service = Woods::MCP::IndexReader.new(output).find_unit('ProvenanceOmitted', type: 'service')
      unless current_service && current_service.fetch('source_code').include?(':after') &&
             !current_service.fetch('source_code').include?(':before')
        raise 'full recovery did not publish the edited service'
      end
      source = source_check.call
      unless source.fetch('unverified_scopes').empty? &&
             source.fetch('scopes').values.all? { |paths| paths.values.all? { |version| version == 'current' } }
        raise 'full recovery did not establish current source identities'
      end
    else
      # Older woods_ref selections predate the source-reference baseline guard.
      run.call('woods:refresh[events]')
      source = source_check.call(omitted => { 'baseline' => before })
      raise 'omitted service was silently certified' unless source.dig('scopes', 'file:services', omitted) == 'retained:baseline'
      raise 'event consumer did not advance' unless source.dig('scopes', 'whole:events', omitted) == 'current'
    end
  end
end
puts 'PASS concern fan-out, unrelated model stability, full equivalence, PORO mutations and source-consumer provenance'
