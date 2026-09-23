# frozen_string_literal: true

# Run outside Rails in the disposable application made by the host runner.
# Every generator, extraction and server below boots a fresh process.
require 'bundler/setup'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'woods'
require_relative '../support/mcp_session'

class WatchAcceptance
  START = '# woods:watch:managed:start'
  FINISH = '# woods:watch:managed:end'
  LEGACY = 'plugin :woods if Gem.loaded_specs.key?("woods")'

  def initialize
    @root = Dir.pwd
    @report_dir = ENV.fetch('WOODS_ACCEPTANCE_REPORT_DIR')
    @index = ENV.fetch('WOODS_OUTPUT')
    @timeout = Float(ENV.fetch('WOODS_ACCEPTANCE_TIMEOUT', '120'))
    @checks = []
    @events = []
    @owned_pids = []
    @http_samples = 0
    @command_number = 0
    @port = Integer(ENV.fetch('PORT', '39391'))
    FileUtils.mkdir_p(@report_dir)
  end

  def run
    identity!
    prepare_fixture
    check('fresh database boots') { command('bin/rails', 'db:prepare', timeout: 180) }
    install!
    check('baseline extraction validates') do
      command('bin/rails', 'woods:extract')
      command('bin/rails', 'woods:validate')
    end
    @baseline = generation
    write_probe('WoodsAcceptanceStartup', 'created_while_stopped')
    check('normal Puma startup catches up stopped-file content') do
      start_puma
      wait_for('HTTP readiness') { web_ready? }
      wait_for('watcher ready') { ready_owner }
      @session = McpSession.new(command: [Gem.ruby, Gem.bin_path('woods', 'woods-mcp'), @index], timeout: 30)
      @reader_pid = @session.pid
      wait_for('startup unit') { unit_contains?('WoodsAcceptanceStartup', 'created_while_stopped') }
      raise 'generation did not advance' unless generation > @baseline
      record('startup')
    end
    exercise_live_reader!
    exercise_restart!
    check('probe deletion reconciles before shutdown') do
      remove_probe('WoodsAcceptanceStartup')
      wait_for('startup probe deletion') { unit_missing?('WoodsAcceptanceStartup') }
      command('bin/rails', 'woods:validate')
      record('clean_index')
    end
    check('Puma shutdown reaps launcher and extraction child') do
      owner = ready_owner or raise 'watcher not ready before shutdown'
      pids = (@owned_pids + owner.values_at('pid', 'child_pid')).uniq
      stop_puma
      wait_for('owned child shutdown', timeout: 20) { pids.none? { |pid| alive?(pid) } }
      raise 'active supervision record survived shutdown' if active_owners.any?
      @session.close
      @session = nil
    end
    check('owned setup removal preserves application configuration') do
      command('bin/rails', 'generate', 'woods:watch', '--operation', 'remove')
      raise 'application Puma configuration changed' unless File.binread('config/puma.rb') == @original_puma
      %w[bin/woods-watch .woods-watch.json].each { |path| raise "owned file remains: #{path}" if File.exist?(path) }
    end
    @passed = true
  rescue StandardError => error
    @error = "#{error.class}: #{error.message}"
    warn @error
  ensure
    [-> { @session&.close }, -> { stop_puma }].each do |cleanup|
      begin
        cleanup.call
      rescue StandardError => error
        @passed = false
        @error = [@error, "cleanup: #{error.class}: #{error.message}"].compact.join("\n")
      end
    end
    report = { status: @passed ? 'PASS' : 'FAIL', identity: @identity, checks: @checks,
               observations: @events, error: @error, final_generation: generation,
               final_puma_pid: @puma, reader_pid: @reader_pid, observed_owned_pids: @owned_pids.uniq,
               http_samples_during_restart: @http_samples }
    File.write(File.join(@report_dir, 'acceptance.json'), JSON.pretty_generate(report) + "\n")
    puts JSON.generate(status: report[:status], checks: @checks.size, report: File.join(@report_dir, 'acceptance.json'))
    return @passed ? 0 : 1
  end

  private

  def identity!
    spec = Gem.loaded_specs.fetch('woods')
    source = Bundler.load.specs.find { |item| item.name == 'woods' }.source.class.name
    mode = ENV.fetch('WOODS_ACCEPTANCE_MODE')
    path = File.realpath(spec.full_gem_path)
    loaded = File.realpath(Woods.method(:configuration).source_location.first)
    raise 'Woods loaded outside activated gem' unless loaded.start_with?(path + '/')
    if mode == 'artifact'
      raise 'artifact resolved from a checkout' unless source == 'Bundler::Source::Rubygems' && !path.start_with?('/woods-gem')
      artifact = ENV.fetch('WOODS_ACCEPTANCE_GEM_FILE')
      expected_digest = ENV.fetch('WOODS_ACCEPTANCE_GEM_SHA256')
      raise 'artifact digest mismatch' unless Digest::SHA256.file(artifact).hexdigest == expected_digest
      unless File.file?(spec.cache_file) && Digest::SHA256.file(spec.cache_file).hexdigest == expected_digest
        raise 'activated installed gem does not match the supplied package'
      end
      raise 'checkout load path leaked' if $LOAD_PATH.any? { |entry| entry.start_with?('/woods-gem') }
    elsif mode == 'source'
      raise 'wrong source mount' unless path == '/woods-gem' && source == 'Bundler::Source::Path'
    else
      raise "unknown mode #{mode.inspect}"
    end
    raise 'BUNDLE_PATH must come from the environment' if ENV['BUNDLE_PATH'].to_s.empty?
    path_settings = Bundler.settings.locations('path')
    unless path_settings[:env] == ENV.fetch('BUNDLE_PATH') && !path_settings.key?(:local)
      raise "bundle path is not solely selected by the environment: #{path_settings.inspect}"
    end
    raise 'this lane requires supported Puma' unless [6, 7, 8].include?(Gem.loaded_specs.fetch('puma').version.segments.first)
    @identity = { mode: mode, revision: ENV.fetch('WOODS_ACCEPTANCE_REVISION'), woods_version: Woods::VERSION,
                  loaded_path: path, loaded_source: loaded, bundler_source: source, ruby: RUBY_VERSION,
                  rails: Gem.loaded_specs.fetch('railties').version.to_s, puma: Gem.loaded_specs.fetch('puma').version.to_s,
                  bundle_path: ENV.fetch('BUNDLE_PATH'), bundle_path_settings: path_settings,
                  artifact_sha256: ENV['WOODS_ACCEPTANCE_GEM_SHA256'] }
    puts JSON.generate(@identity)
  end

  def prepare_fixture
    @original_puma = "# Acceptance fixture: application-owned configuration\nthreads 2, 2\n"
    File.write('config/puma.rb', @original_puma)
    File.write('config/initializers/woods_acceptance.rb', "Rails.application.config.time_zone = 'UTC'\n")
    routes = File.read('config/routes.rb')
    needle = 'Rails.application.routes.draw do'
    raise 'unexpected routes fixture' unless routes.include?(needle)
    health = 'get "/__woods_acceptance", to: proc { [200, {"content-type" => "text/plain"}, ["woods-ready"]] }'
    File.write('config/routes.rb', routes.sub(needle, "#{needle}\n  #{health}"))
    FileUtils.mkdir_p('app/services')
  end

  def install!
    snapshot = installation_files
    check('setup preview makes no writes') do
      command('bin/rails', 'generate', 'woods:watch', '--mode', 'puma', '--pretend')
      raise 'preview changed installation files' unless installation_files == snapshot
    end
    protected = bundle_files
    check('default-command setup preserves bundle settings and lock') do
      command('bin/rails', 'generate', 'woods:watch', '--mode', 'puma')
      raise 'bundle files changed' unless bundle_files == protected
      receipt = JSON.parse(File.read('.woods-watch.json'))
      raise 'wrong default child command' unless receipt.dig('selection', 'child_command') == ['bin/rails', 'woods:watch']
      raise 'wrapper is not executable' unless File.executable?('bin/woods-watch')
    end
    wrapper = File.binread('bin/woods-watch')
    receipt = JSON.parse(File.read('.woods-watch.json'))
    current = receipt.fetch('sections').fetch('config/puma.rb').fetch('owned_text')
    legacy = [START, LEGACY, FINISH, ''].join("\n")
    File.write('config/puma.rb', File.read('config/puma.rb').sub(current, legacy))
    receipt.fetch('sections').fetch('config/puma.rb')['owned_text'] = legacy
    File.write('.woods-watch.json', JSON.pretty_generate(receipt) + "\n")
    snapshot = installation_files
    check('legacy update preview makes no writes') do
      command('bin/rails', 'generate', 'woods:watch', '--operation', 'update', '--mode', 'puma', '--pretend')
      raise 'update preview changed files' unless installation_files == snapshot
    end
    check('legacy update refreshes only owned guard and receipt') do
      command('bin/rails', 'generate', 'woods:watch', '--operation', 'update', '--mode', 'puma')
      updated = JSON.parse(File.read('.woods-watch.json')).fetch('sections').fetch('config/puma.rb').fetch('owned_text')
      raise 'legacy guard retained' if updated.include?(LEGACY)
      raise 'capability guard missing' unless updated.include?('full_require_paths') && updated.include?('puma/plugin/woods.rb')
      raise 'unowned Puma content changed' unless File.read('config/puma.rb') == @original_puma + updated
      raise 'wrapper changed' unless File.binread('bin/woods-watch') == wrapper
      raise 'bundle files changed' unless bundle_files == protected
      snapshot = installation_files
      command('bin/rails', 'generate', 'woods:watch', '--operation', 'update', '--mode', 'puma')
      raise 'update not idempotent' unless installation_files == snapshot
    end
  end

  def exercise_live_reader!
    check('one MCP session observes create') do
      raise 'probe already indexed' unless unit_missing?('WoodsAcceptanceLive')
      write_probe('WoodsAcceptanceLive', 'first_method')
      wait_for('created unit') { unit_contains?('WoodsAcceptanceLive', 'first_method') }
      record('create')
    end
    check('same MCP session observes edit') do
      write_probe('WoodsAcceptanceLive', 'second_method')
      wait_for('edited unit') do
        unit_contains?('WoodsAcceptanceLive', 'second_method') && !unit_contains?('WoodsAcceptanceLive', 'first_method')
      end
      record('edit')
    end
    check('same MCP session observes deletion') do
      remove_probe('WoodsAcceptanceLive')
      wait_for('deleted unit') { unit_missing?('WoodsAcceptanceLive') }
      record('delete')
    end
  end

  def exercise_restart!
    check('initializer restart converges while Puma and MCP stay alive') do
      owner = ready_owner or raise 'watcher not ready before restart'
      File.write('config/initializers/woods_acceptance.rb', "Rails.application.config.time_zone = 'Hawaii'\n")
      wait_for('replacement child and new runtime configuration') do
        replacement = ready_owner
        raise 'Puma exited during watcher restart' unless alive?(@puma)
        raise 'HTTP became unavailable during watcher restart' unless web_ready?
        @http_samples += 1
        replacement && replacement['pid'] == owner['pid'] && replacement['child_pid'] != owner['child_pid'] &&
          !alive?(owner['child_pid']) && unit_contains?('BehavioralProfile', 'Hawaii')
      end
      raise 'duplicate live launchers' unless active_owners.size == 1
      raise 'Puma unavailable after restart' unless web_ready?
      record('initializer_restart')
    end
  end

  def check(name)
    started = monotonic
    yield
    @checks << { name: name, status: 'PASS', seconds: (monotonic - started).round(3) }
    puts "PASS #{name}"
  rescue StandardError => error
    @checks << { name: name, status: 'FAIL', error: "#{error.class}: #{error.message}" }
    raise
  end

  def command(*args, timeout: @timeout)
    @command_number += 1
    log = File.join(@report_dir, format('%02d-command.log', @command_number))
    File.open(log, 'w') do |output|
      output.puts(args.inspect)
      pid = Process.spawn(*args, out: output, err: [:child, :out], pgroup: true)
      _, status = Timeout.timeout(timeout) { Process.wait2(pid) }
      raise "command failed (#{status.exitstatus}): #{args.inspect}; see #{log}" unless status.success?
    ensure
      if pid && alive?(pid)
        Process.kill('KILL', -pid)
        Process.wait(pid)
      end
    end
  end

  def start_puma
    @puma_log = File.open(File.join(@report_dir, 'puma.log'), 'w')
    @puma = Process.spawn('bin/rails', 'server', '-b', '127.0.0.1', '-p', @port.to_s,
                          in: File::NULL, out: @puma_log, err: [:child, :out], pgroup: true)
  end

  def stop_puma
    return unless @puma

    if (early = Process.waitpid2(@puma, Process::WNOHANG))
      @puma = nil
      raise "Puma exited before shutdown was requested: #{early.last.inspect}"
    end
    Process.kill('TERM', @puma)
    _, status = Timeout.timeout(30) { Process.wait2(@puma) }
    @puma = nil
    # Puma's default raise_exception_on_sigterm re-raises the requested signal
    # after its shutdown hooks. Both zero and that exact signal are expected;
    # neither substitutes for checking every observed watcher PID below.
    normal = status.success? || (status.signaled? && status.termsig == Signal.list.fetch('TERM'))
    raise "Puma exited unexpectedly: #{status.inspect}" unless normal
  rescue Errno::ECHILD
    @puma = nil
  rescue Timeout::Error
    Process.kill('KILL', -@puma) if alive?(@puma)
    Process.wait(@puma)
    @puma = nil
    raise 'Puma did not shut down within 30 seconds'
  ensure
    @puma_log&.close
  end

  def web_ready?
    http = Net::HTTP.new('127.0.0.1', @port, nil)
    http.open_timeout = 1
    http.read_timeout = 2
    response = http.get('/__woods_acceptance')
    response.code == '200' && response.body == 'woods-ready'
  rescue IOError, SystemCallError, Timeout::Error
    false
  end

  def wait_for(label, timeout: @timeout)
    deadline = monotonic + timeout
    until yield
      raise "timed out waiting for #{label}; see puma.log" if monotonic >= deadline
      sleep 0.2
    end
  end

  def lookup(identifier)
    raise 'reader process changed' unless @session.pid == @reader_pid
    @session.request('tools/call', { name: 'lookup', arguments: { identifier: identifier } })
  end

  def unit_contains?(identifier, marker)
    result = lookup(identifier)
    return false if result['isError'] && result.dig('_meta', 'error_code') == 'not_found'
    raise "lookup failed: #{result.inspect}" if result['isError']
    result.fetch('content').any? { |part| part['type'] == 'text' && part['text'].include?(identifier) && part['text'].include?(marker) }
  end

  def unit_missing?(identifier)
    result = lookup(identifier)
    return true if result['isError'] && result.dig('_meta', 'error_code') == 'not_found'
    raise "lookup failed: #{result.inspect}" if result['isError']
    false
  end

  def active_owners
    Dir[File.join(@index, 'watch_supervisors', '*.json')].map { |path| JSON.parse(File.read(path)) }
      .select { |owner| alive?(owner['pid']) && owner['state'] != 'stopped' }
  end

  def ready_owner
    owners = active_owners
    raise 'multiple active watcher launchers' if owners.size > 1
    owners.find { |owner| owner['state'] == 'ready' && alive?(owner['child_pid']) }
  end

  def alive?(pid)
    return false unless pid.is_a?(Integer) && pid.positive?
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def probe_path(name)
    "app/services/#{name.gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase}.rb"
  end

  def write_probe(name, method)
    File.write(probe_path(name), "class #{name}\n  def #{method}\n    :acceptance_probe\n  end\nend\n")
  end

  def remove_probe(name)
    File.unlink(probe_path(name))
  end

  def generation
    path = File.join(@index, 'generation.json')
    File.file?(path) ? JSON.parse(File.read(path)).fetch('number') : 0
  end

  def record(event)
    owner = ready_owner or raise "watcher not ready at #{event}"
    @owned_pids.concat(owner.values_at('pid', 'child_pid'))
    @events << { event: event, generation: generation, puma_pid: @puma, reader_pid: @session.pid,
                 supervisor: owner }
  end

  def installation_files
    paths = %w[config/puma.rb bin/woods-watch .woods-watch.json]
    paths.to_h { |path| [path, File.file?(path) ? [File.binread(path), File.stat(path).mode & 0o777] : nil] }.merge(bundle_files)
  end

  def bundle_files
    paths = ['Gemfile', 'Gemfile.lock', '.bundle/config', File.join(ENV.fetch('BUNDLE_APP_CONFIG', '.bundle'), 'config')]
    paths.uniq.to_h { |path| [path, File.file?(path) ? File.binread(path) : nil] }
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

exit WatchAcceptance.new.run
