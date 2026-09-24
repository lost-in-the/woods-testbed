# frozen_string_literal: true

# Rails runner child: each operation gets a fresh boot and its own bounded log.
# Timings cover extraction, not process/Rails boot; VmHWM covers the whole child.
require 'json'
require 'digest'
require 'woods/extractor'
require 'woods/generation'
require_relative 'woods_phase_logger'

options = JSON.parse(ENV.fetch('WOODS_REFERENCE_OPERATION'))
report = { operation: options.fetch('operation'), index: options.fetch('index') }
spec = Gem.loaded_specs.fetch('woods')
report[:loaded_path] = File.realpath(spec.full_gem_path)
report[:woods_version] = spec.version.to_s
if ENV['WOODS_REFERENCE_EXPECTED_PATH']
  raise 'performance child loaded wrong Woods tree' unless report[:loaded_path] == ENV.fetch('WOODS_REFERENCE_EXPECTED_PATH')
end
logger = PhaseLogger.new
Rails.logger = logger
ENV['WOODS_PROFILE'] = '1'
Woods.configure do |config|
  config.concurrent_extraction = false
  config.enable_snapshots = false
  config.extract_rails_source = false if config.respond_to?(:extract_rails_source=)
end
begin
  if options['fault_path']
    # Fail inside extraction, after a valid app has booted, not merely at load.
    Rails.application.eager_load!
    fault_path = Rails.root.join(options.fetch('fault_path'))
    original = File.binread(fault_path)
    File.write(fault_path, "class ReferencePoro; def\n")
  end
  extractor = Woods::Extractor.new(output_dir: options.fetch('index'))
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = case options.fetch('operation')
           when 'full' then extractor.extract_all
           when 'incremental' then extractor.extract_changed(options.fetch('paths'))
           when 'refresh' then extractor.refresh(*options.fetch('types').map(&:to_sym))
           else raise "unknown operation #{options['operation']}"
           end
  extractor.raise_on_publication_failure!
  finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  graph = extractor.dependency_graph.to_h
  touched = case options.fetch('operation')
            when 'full' then result.values.flatten.map(&:identifier)
            when 'refresh' then result.fetch(:touched)
            else result
            end
  rss = File.read('/proc/self/status').lines.find { |line| line.start_with?('VmHWM:') }
  report.merge!(status: 'PASS', wall_ms: ((finished - started) * 1000).round(3),
                phases_ms: logger.phase_durations(started, finished), profile_lines: logger.profile_lines,
                peak_process_rss_kib: rss && rss.split[1].to_i,
                affected_units: touched.size, touched: touched.sort,
                nodes: graph.fetch(:stats).fetch(:node_count), edges: graph.fetch(:stats).fetch(:edge_count),
                fixture_blast_radius: extractor.dependency_graph.affected_by(
                  [Rails.root.join('app/models/reference_target.rb').to_s]
                ).size)
rescue StandardError => error
  report.merge!(status: 'FAIL', error: "#{error.class}: #{error.message}", backtrace: error.backtrace&.first(12))
ensure
  File.binwrite(fault_path, original) if original
  File.write(options.fetch('report'), JSON.pretty_generate(report) + "\n")
end
abort(report.fetch(:error)) unless report[:status] == 'PASS'
