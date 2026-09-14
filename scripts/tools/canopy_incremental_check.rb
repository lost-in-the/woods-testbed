# frozen_string_literal: true
# Copy source into a disposable app; never modify the interactive working tree.
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'woods/mcp/index_reader'
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
  path = 'app/models/concerns/archivable.rb'
  full_path = File.join(scratch, path)
  original = File.read(full_path)
  File.write(full_path, original.sub(/\nend\s*\z/, "\n  def canopy_incremental_probe\n    :present\n  end\nend\n"))
  run.call('woods:incremental', path)
  incremental = semantic.call
  %w[Article Comment Billing::Invoice].each do |identifier|
    raise "Concern not refreshed for #{identifier}" unless incremental.fetch(['model', identifier]).first.include?('canopy_incremental_probe')
  end
  raise 'Unrelated billing plan changed' unless incremental.fetch(['model', 'Billing::Plan']) == baseline.fetch(['model', 'Billing::Plan'])
  run.call('woods:clean')
  run.call('woods:extract')
  raise 'Concern incremental differs from full extraction' unless semantic.call == incremental
  File.write(full_path, original)
  run.call('woods:incremental', path)
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
end
puts 'PASS concern fan-out, unrelated model stability, full equivalence, and PORO addition/removal'
