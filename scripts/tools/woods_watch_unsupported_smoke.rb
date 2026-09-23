# frozen_string_literal: true

# Explicit floor-fixture lane: run with bundle exec ruby, outside rails runner.
require 'bundler/setup'
require 'digest'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'timeout'
require 'woods'

def protected_snapshot(paths)
  paths.to_h do |path|
    raise "expected a regular protected file: #{path}" if File.exist?(path) && !File.file?(path)

    value = File.file?(path) ? { bytes: File.binread(path), mode: File.stat(path).mode & 0o777 } : nil
    [path, value]
  end
end

def snapshot_evidence(snapshot)
  snapshot.transform_values do |file|
    file && { sha256: Digest::SHA256.hexdigest(file.fetch(:bytes)), mode: file.fetch(:mode) }
  end
end

def assertion(checks, name)
  yield
  checks << { name: name, status: 'PASS' }
rescue StandardError => error
  checks << { name: name, status: 'FAIL', error: error.message }
  raise
end

root = Dir.pwd
report_dir = File.expand_path(ENV.fetch('WOODS_UNSUPPORTED_REPORT_DIR', 'tmp/woods-watcher-unsupported'))
FileUtils.mkdir_p(report_dir)
checks = []
report = { status: 'FAIL', checks: checks }
before = nil
pid = nil
begin
  puma = Gem.loaded_specs.fetch('puma').version
  woods = Gem.loaded_specs.fetch('woods')
  report[:identity] = {
    ruby: RUBY_VERSION, rails: Gem.loaded_specs.fetch('railties').version.to_s,
    puma: puma.to_s, woods_version: Woods::VERSION, woods_path: woods.full_gem_path,
    bundler_source: Bundler.load.specs.find { |spec| spec.name == 'woods' }.source.class.name
  }
  assertion(checks, 'supported-floor fixture actually loads Puma 4.3') do
    raise "expected Puma 4.3, loaded #{puma}" unless puma.segments.first(2) == [4, 3]
  end
  timeout = Float(ENV.fetch('WOODS_UNSUPPORTED_TIMEOUT', '120'))
  raise 'WOODS_UNSUPPORTED_TIMEOUT must be positive' unless timeout.positive?

  protected_paths = %w[config/puma.rb bin/woods-watch .woods-watch.json Gemfile Gemfile.lock .bundle/config]
                    .map { |path| File.join(root, path) }
  # The fixture Dockerfile may place active Bundler config outside the app.
  protected_paths << File.join(Bundler.app_config_path.to_s, 'config')
  before = protected_snapshot(protected_paths.uniq)
  report[:before] = snapshot_evidence(before)
  log_path = File.join(report_dir, 'generator.log')
  File.open(log_path, 'wb') do |log|
    command = [RbConfig.ruby, 'bin/rails', 'generate', 'woods:watch', '--operation', 'setup', '--mode', 'puma']
    log.puts(command.inspect)
    log.flush
    pid = Process.spawn(*command, pgroup: true, out: log, err: [:child, :out])
    _, status = Timeout.timeout(timeout) { Process.wait2(pid) }
    pid = nil
    report[:generator_exit_status] = status.exitstatus
    after = protected_snapshot(before.keys)
    report[:after] = snapshot_evidence(after)
    # Check writes first even if the process also has a wrong success status.
    before.each do |path, original|
      name = path.start_with?(root + '/') ? path.delete_prefix(root + '/') : path
      assertion(checks, "refusal preserves #{name}") { raise "generator changed #{name}" unless after.fetch(path) == original }
    end
    assertion(checks, 'unsupported generator exits nonzero') do
      raise 'generator did not return a nonzero exit code' unless status.exited? && status.exitstatus != 0
    end
  end
  assertion(checks, 'refusal explains supported Puma versions and external supervision') do
    diagnostic = File.read(log_path)
    unless diagnostic.match?(/Supported Puma 6\/7\/8.*required; use external supervision/)
      raise "expected unsupported-Puma diagnostic; see #{log_path}"
    end
  end
  report[:status] = 'PASS'
rescue StandardError => error
  report[:error] = "#{error.class}: #{error.message}"
ensure
  if pid
    Process.kill('KILL', -pid) rescue nil
    Process.wait(pid) rescue nil
  end
  # A failed no-write assertion must not contaminate later extraction tests.
  if before
    before.each do |path, original|
      begin
        next if protected_snapshot([path]).fetch(path) == original

        if original
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, original.fetch(:bytes))
          File.chmod(original.fetch(:mode), path)
        else
          File.unlink(path) if File.file?(path)
        end
      rescue StandardError => error
        report[:status] = 'FAIL'
        (report[:cleanup_errors] ||= []) << "#{path}: #{error.message}"
      end
    end
  end
  File.write(File.join(report_dir, 'unsupported.json'), JSON.pretty_generate(report) + "\n")
  puts JSON.pretty_generate(report)
end
exit(report.fetch(:status) == 'PASS' ? 0 : 1)
