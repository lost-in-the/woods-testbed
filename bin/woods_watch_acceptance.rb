#!/usr/bin/env ruby
# frozen_string_literal: true

# Host-side runner. The lifecycle test itself runs in a disposable container.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'securerandom'
require 'tmpdir'
require 'timeout'

options = { docker: 'docker', timeout: 1800 }
parser = OptionParser.new do |p|
  p.banner = 'Usage: ruby bin/woods_watch_acceptance.rb (--woods DIR | --gem FILE --sha256 DIGEST) --revision SHA [options]'
  p.on('--woods DIR', 'Test an exact committed snapshot of this checkout') { |v| options[:woods] = File.expand_path(v) }
  p.on('--gem FILE', 'Test this installed package, without a source mount') { |v| options[:gem] = File.expand_path(v) }
  p.on('--sha256 DIGEST', 'Required expected digest for --gem') { |v| options[:sha256] = v.downcase }
  p.on('--revision SHA', 'Expected full source revision (package provenance in artifact mode)') { |v| options[:revision] = v.downcase }
  p.on('--report-dir DIR', 'New or empty host evidence directory; default: a retained temporary directory') { |v| options[:report_dir] = File.expand_path(v) }
  p.on('--image NAME', 'Use an existing Canopy Dockerfile image instead of building') { |v| options[:image] = v }
  p.on('--docker PATH', 'Docker executable; a single path, never a shell command') { |v| options[:docker] = v }
  p.on('--docker-sudo', 'Prefix Docker commands with sudo -n') { options[:sudo] = true }
  p.on('--timeout SECONDS', Integer, 'Container lifetime limit including bundle install (default: 1800)') { |v| options[:timeout] = v }
  p.on('-h', '--help') { puts p; exit }
end

def capture!(*argv)
  output, error, status = Open3.capture3(*argv)
  raise "#{argv.first} failed: #{error.strip}" unless status.success?

  output
end

# Every potentially long Docker operation has a deadline. Kill the CLI process
# group on expiry; the ensure block separately removes our named container.
def command!(argv, log_path, timeout: 120)
  File.open(log_path, 'ab') do |log|
    log.puts("\n$ #{argv.map(&:inspect).join(' ')}")
    log.flush
    pid = Process.spawn(*argv, pgroup: true, out: log, err: [:child, :out])
    begin
      _, status = Timeout.timeout(timeout) { Process.wait2(pid) }
      raise "command exited #{status.exitstatus || status.termsig}: #{argv.first}; see #{log_path}" unless status.success?
    rescue Timeout::Error
      Process.kill('TERM', -pid) rescue nil
      begin
        Timeout.timeout(5) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill('KILL', -pid) rescue nil
        Process.wait(pid) rescue nil
      end
      raise "command exceeded #{timeout}s: #{argv.first}; see #{log_path}"
    end
  end
end

begin
  parser.parse!
  raise OptionParser::InvalidArgument, 'unexpected positional arguments' unless ARGV.empty?
  raise OptionParser::InvalidArgument, 'choose exactly one of --woods or --gem' unless !!options[:woods] ^ !!options[:gem]
  raise OptionParser::InvalidArgument, '--revision must be a full 40-character SHA' unless options[:revision]&.match?(/\A[0-9a-f]{40}\z/)
  raise OptionParser::InvalidArgument, '--timeout must be positive' unless options[:timeout].positive?
  if options[:gem]
    raise OptionParser::InvalidArgument, '--sha256 must be a 64-character digest' unless options[:sha256]&.match?(/\A[0-9a-f]{64}\z/)
    # Intentionally before any Docker invocation or host resource creation.
    actual = Digest::SHA256.file(options[:gem]).hexdigest
    raise "artifact SHA256 mismatch: expected #{options[:sha256]}, got #{actual}" unless actual == options[:sha256]
  elsif options[:sha256]
    raise OptionParser::InvalidArgument, '--sha256 requires --gem'
  else
    actual = capture!('git', '-C', options[:woods], 'rev-parse', 'HEAD').strip
    raise "source revision mismatch: expected #{options[:revision]}, got #{actual}" unless actual == options[:revision]
  end
rescue StandardError => e
  warn "ERROR: #{e.message}"
  exit 1
end

repo = File.expand_path('..', __dir__)
report = options[:report_dir] || Dir.mktmpdir('woods-watch-evidence-')
abort "ERROR: report directory must be empty: #{report}" if File.directory?(report) && !Dir.empty?(report)
FileUtils.mkdir_p(report)
log = File.join(report, 'runner.log')
docker = [*('sudo' if options[:sudo]), *('-n' if options[:sudo]), options[:docker]]
run_id = "woods-watch-#{SecureRandom.hex(6)}"
mode = options[:gem] ? 'artifact' : 'source'
testbed_status = capture!('git', '-C', repo, 'status', '--porcelain', '--untracked-files=all')
evidence = {
  mode: mode, expected_revision: options[:revision], gem_sha256: options[:sha256],
  testbed_revision: capture!('git', '-C', repo, 'rev-parse', 'HEAD').strip,
  testbed_dirty: !testbed_status.empty?, testbed_status: testbed_status,
  runner_sha256: Digest::SHA256.file(__FILE__).hexdigest,
  container: run_id, image: options[:image] || run_id, report_directory: report,
  final_release_validation: false, cleanup_errors: []
}
if options[:woods]
  source_status = capture!('git', '-C', options[:woods], 'status', '--porcelain', '--untracked-files=all')
  evidence[:source_checkout] = { dirty: !source_status.empty?, status: source_status,
                                 tested_content: 'committed snapshot; working-tree edits excluded' }
end
container_creation_attempted = false
image_created = false
exit_code = 1
puts "Watcher acceptance (#{mode}); evidence: #{report}"

begin
  Dir.mktmpdir('woods-watch-run-') do |scratch|
    # Archive tracked fixture bytes: no developer database, bundle config,
    # credentials, generated app tree, or old index is copied. The generator's
    # protected-file baseline is captured after bundle installation finishes.
    fixture_archive = File.join(scratch, 'fixture.tar')
    command!(['git', '-C', repo, 'archive', '--format=tar', "--output=#{fixture_archive}", evidence[:testbed_revision], 'apps/rails-8.0-large'], log)
    command!(['tar', '-xf', fixture_archive, '-C', scratch], log)
    fixture = File.join(scratch, 'apps/rails-8.0-large')
    evidence[:fixture_archive_sha256] = Digest::SHA256.file(fixture_archive).hexdigest

    # Freeze working harness edits before boot so the manifest describes the
    # exact executed files even if the developer keeps editing during the run.
    harness = File.join(scratch, 'harness')
    FileUtils.cp_r(File.join(repo, 'scripts'), harness)
    manifest = Dir.glob(File.join(harness, '**', '*'), File::FNM_DOTMATCH).sort.each_with_object({}) do |path, files|
      next unless File.file?(path)

      files[path.delete_prefix(harness + '/')] = Digest::SHA256.file(path).hexdigest
    end
    evidence[:harness_files_sha256] = manifest
    evidence[:harness_manifest_sha256] = Digest::SHA256.hexdigest(JSON.generate(manifest))

    if options[:woods]
      woods_archive = File.join(scratch, 'woods.tar')
      woods_snapshot = File.join(scratch, 'woods')
      FileUtils.mkdir_p(woods_snapshot)
      command!(['git', '-C', options[:woods], 'archive', '--format=tar', "--output=#{woods_archive}", options[:revision]], log)
      command!(['tar', '-xf', woods_archive, '-C', woods_snapshot], log)
      evidence[:source_archive_sha256] = Digest::SHA256.file(woods_archive).hexdigest
    end

    bootstrap = File.join(scratch, 'bootstrap.rb')
    File.write(bootstrap, <<~'RUBY')
      require 'fileutils'
      require 'rubygems/package'
      require 'rbconfig'
      require 'digest'

      FileUtils.mkdir_p(['/app', '/evidence', '/scratch/index'])
      FileUtils.cp_r('/fixture/.', '/app')
      Dir.chdir('/app')
      if ENV.fetch('WOODS_ACCEPTANCE_MODE') == 'artifact'
        artifact = ENV.fetch('WOODS_ACCEPTANCE_GEM_FILE')
        expected = ENV.fetch('WOODS_ACCEPTANCE_GEM_SHA256')
        abort 'artifact changed after host digest check' unless Digest::SHA256.file(artifact).hexdigest == expected
        spec = Gem::Package.new(artifact).spec
        abort "expected woods gem, got #{spec.name}" unless spec.name == 'woods'
        gemfile = File.read('Gemfile')
        old = 'gem "woods", path: "/woods-gem"'
        abort 'fixture Woods dependency changed; update runner' unless gemfile.scan(old).length == 1
        File.write('Gemfile', gemfile.sub(old, "gem \"woods\", \"= #{spec.version}\""))
        install_dir = File.join(ENV.fetch('BUNDLE_PATH'), 'ruby', RbConfig::CONFIG.fetch('ruby_version'))
        abort 'artifact installation failed' unless system('gem', 'install', '--local', artifact, '--ignore-dependencies', '--no-document', '--install-dir', install_dir)
        # Bundler can satisfy this exact version from the installed package.
        # Keep the supplied bytes in its local package cache too.
        FileUtils.mkdir_p('vendor/cache')
        FileUtils.cp(artifact, "vendor/cache/woods-#{spec.version}.gem")
      end
      abort 'bundle install failed' unless system('bundle', 'install', '--jobs', '4', '--retry', '2')
      exec('bundle', 'exec', 'ruby', '/harness/tools/woods_watch_acceptance.rb')
    RUBY

    unless options[:image]
      puts "Building isolated Canopy image #{run_id} (up to 20 minutes)."
      image_created = true
      command!([*docker, 'build', '--tag', run_id, fixture], log, timeout: 1200)
    end

    env = {
      'BUNDLE_PATH' => '/bundle', 'BUNDLE_APP_CONFIG' => '/app/.bundle',
      'RAILS_ENV' => 'development', 'TESTBED_DATA_PROFILE' => 'smoke',
      'WOODS_OUTPUT' => '/scratch/index', 'PORT' => '39391',
      'WOODS_WATCH_POLL' => '1', 'WOODS_WATCH_POLL_INTERVAL' => '0.1', 'WOODS_WATCH_DEBOUNCE' => '0.1',
      'WOODS_ACCEPTANCE_REPORT_DIR' => '/evidence', 'WOODS_ACCEPTANCE_MODE' => mode,
      'WOODS_ACCEPTANCE_REVISION' => options[:revision]
    }
    mounts = [[fixture, '/fixture'], [harness, '/harness'], [bootstrap, '/bootstrap.rb']]
    if options[:woods]
      mounts << [woods_snapshot, '/woods-gem']
    else
      mounts << [options[:gem], '/artifact/woods.gem']
      env['WOODS_ACCEPTANCE_GEM_FILE'] = '/artifact/woods.gem'
      env['WOODS_ACCEPTANCE_GEM_SHA256'] = options[:sha256]
    end
    # --mount's comma-separated syntax cannot represent commas in source paths.
    raise 'mount paths must not contain commas' if mounts.any? { |source, _| source.include?(',') }

    # The daemon can create the resource even when its CLI then fails or loses
    # its connection. Attempt cleanup by our unique name in either case.
    container_creation_attempted = true
    command!([
      *docker, 'create', '--name', run_id, '--init', '--workdir', '/app',
      *env.flat_map { |key, value| ['--env', "#{key}=#{value}"] },
      *mounts.flat_map { |source, target| ['--mount', "type=bind,source=#{source},target=#{target},readonly"] },
      '--entrypoint', 'ruby', options[:image] || run_id, '/bootstrap.rb'
    ], log)
    puts "Running isolated bundle install and acceptance (up to #{options[:timeout]} seconds)."
    command!([*docker, 'start', '--attach', run_id], log, timeout: options[:timeout])
    exit_code = 0
  ensure
    if container_creation_attempted
      # Stop before copying so timed-out tests cannot mutate the evidence while
      # it is collected. No named/shared volume, network or Compose service exists.
      [
        ['stop', '--time', '10', run_id],
        ['cp', "#{run_id}:/evidence/.", report],
        ['rm', '--force', run_id]
      ].each do |args|
        begin
          command!([*docker, *args], log, timeout: 60)
        rescue StandardError => e
          evidence[:cleanup_errors] << e.message
        end
      end
    end
    if image_created
      begin
        command!([*docker, 'image', 'rm', run_id], log, timeout: 60)
      rescue StandardError => e
        evidence[:cleanup_errors] << e.message
      end
    end
  end
  acceptance = JSON.parse(File.read(File.join(report, 'acceptance.json')))
  raise 'harness did not report PASS' unless acceptance.fetch('status') == 'PASS'
  checks = acceptance.fetch('checks')
  raise 'harness checks are missing or failed' unless checks.is_a?(Array) && !checks.empty? && checks.all? { |check| check.fetch('status') == 'PASS' }
  identity = acceptance.fetch('identity')
  raise 'harness mode differs from requested mode' unless identity.fetch('mode') == mode
  raise 'harness revision differs from requested revision' unless identity.fetch('revision') == options[:revision]
  evidence[:acceptance_checks] = checks.length
rescue StandardError => e
  exit_code = 1
  evidence[:error] = e.message
  warn "ERROR: #{e.message}"
ensure
  exit_code = 1 unless evidence[:cleanup_errors].empty?
  evidence[:exit_code] = exit_code
  File.write(File.join(report, 'runner.json'), JSON.pretty_generate(evidence) + "\n")
  puts "Evidence retained: #{report} (exit #{exit_code})"
end
exit exit_code
