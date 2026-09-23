# frozen_string_literal: true

require 'rbconfig'
require 'tmpdir'
require_relative '../support/mcp_session'

def assert(name)
  yield
  puts "PASS #{name}"
  true
rescue StandardError => e
  puts "FAIL #{name}: #{e.class}: #{e.message}"
  false
end

def expect_error(type, text)
  yield
rescue type => e
  raise "wrong error: #{e.message}" unless e.message.include?(text)

  e
else
  raise "expected #{type} containing #{text.inspect}"
end

def with_session(fixture, mode = 'normal', pid_file = '')
  session = McpSession.new(command: [RbConfig.ruby, fixture, mode, pid_file], timeout: 2)
  yield session
ensure
  session&.close
end

def running?(pid)
  # Linux may briefly retain an orphan zombie until PID 1 reaps it. It has no
  # executable code or open pipes and cannot be killed a second time.
  stat = "/proc/#{pid}/stat"
  return false if File.exist?(stat) && File.read(stat).match?(/\) Z /)

  Process.kill(0, pid)
  true
rescue Errno::ESRCH, Errno::ENOENT
  false
end

results = []
Dir.mktmpdir('mcp-session-self-test') do |root|
  fixture = File.join(root, 'server.rb')
  File.write(fixture, <<~'RUBY')
    require 'json'
    mode, pid_file = ARGV
    STDOUT.sync = true
    STDERR.sync = true
    STDERR.write('x' * 200_000 + 'stderr-tail-marker') if mode == 'stderr'
    ready = false
    sequence = 0
    STDIN.each_line do |line|
      request = JSON.parse(line)
      method = request.fetch('method')
      if method == 'notifications/initialized'
        ready = true
        next
      end
      id = request.fetch('id')
      if method == 'initialize'
        result = { 'protocolVersion' => request.dig('params', 'protocolVersion'), 'capabilities' => {},
                   'serverInfo' => { 'name' => 'fixture', 'version' => '1' } }
      else
        sequence += 1
        case mode
        when 'noise'
          puts 'a server log on stdout'
          next
        when 'blank'
          puts
          next
        when 'nonprotocol'
          puts JSON.generate('log' => 'a JSON log is not JSON-RPC')
          next
        when 'wrong_id'
          id += 100
        when 'eof'
          STDERR.puts 'intentional-eof-marker'
          exit 42
        when 'timeout'
          fork do
            trap('TERM', 'IGNORE')
            File.write(pid_file, Process.pid.to_s)
            sleep 60
          end
          sleep 60
        end
        if method == 'rpc_error'
          puts JSON.generate('jsonrpc' => '2.0', 'id' => id,
                             'error' => { 'code' => -32601, 'message' => 'deliberate missing method' })
          next
        end
        if method == 'tools/call'
          result = { 'isError' => request.dig('params', 'name') == 'bad',
                     'content' => [{ 'type' => 'text', 'text' => 'tool marker' }] }
        else
          puts JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/message',
                             'params' => { 'level' => 'info', 'data' => 'notification before response' })
          result = { 'pid' => Process.pid, 'ready' => ready, 'sequence' => sequence, 'params' => request['params'] }
        end
      end
      puts JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result)
    end
    if mode == 'shutdown_hang'
      fork do
        trap('TERM', 'IGNORE')
        File.write(pid_file, Process.pid.to_s)
        sleep 60
      end
    end
    exit(mode == 'bad_exit' ? 42 : 0)
  RUBY

  results << assert('initialize/initialized and repeated requests use one process, matching IDs through notifications') do
    with_session(fixture) do |session|
      first = session.request('echo', { 'first' => true })
      second = session.request('echo', { 'second' => true })
      raise 'server PID changed' unless [first['pid'], second['pid']].all? { |pid| pid == session.pid }
      raise 'initialized notification missing' unless first['ready'] && second['ready']
      raise 'responses were not correlated' unless first['sequence'] == 1 && second['sequence'] == 2 &&
                                                    second['params'] == { 'second' => true }
      raise 'tool failed' unless session.call_tool('good')['isError'] == false
      status = session.close
      raise 'unclean shutdown' unless status.success? && !running?(session.pid)
      raise 'close is not idempotent' unless session.close.nil?
    end
  end

  results << assert('stderr is drained without blocking and only its bounded tail is retained') do
    with_session(fixture, 'stderr') do |session|
      session.request('echo')
      # A stdout response does not synchronize the separate stderr drainer.
      # Closing joins both drains before asserting the complete retained tail.
      session.close
      tail = session.stderr_text
      raise "unexpected buffer size #{tail.bytesize}" unless tail.bytesize <= McpSession::STDERR_LIMIT
      raise 'stderr tail lost' unless tail.end_with?('stderr-tail-marker')
    end
  end

  %w[noise blank nonprotocol wrong_id].each do |mode|
    results << assert("#{mode} stdout cannot satisfy a request") do
      with_session(fixture, mode) do |session|
        expect_error(McpSession::Error, mode == 'wrong_id' ? 'unexpected response ID' : 'stdout line') do
          session.request('echo')
        end
        raise 'failed server remains running' if running?(session.pid)
      end
    end
  end

  results << assert('JSON-RPC and tool errors remain visible while a healthy connection stays usable') do
    with_session(fixture) do |session|
      expect_error(McpSession::RequestError, 'deliberate missing method') { session.request('rpc_error') }
      expect_error(McpSession::ToolError, 'tool marker') { session.call_tool('bad') }
      raise 'connection stopped after remote error' unless session.request('echo')['pid'] == session.pid
    end
  end

  results << assert('unexpected EOF reports stderr and cleans up the process') do
    with_session(fixture, 'eof') do |session|
      error = expect_error(McpSession::Error, 'stdout EOF') { session.request('echo') }
      raise 'stderr diagnostic absent' unless error.message.include?('intentional-eof-marker')
      raise 'EOF server remains running' if running?(session.pid)
    end
  end

  results << assert('request timeout kills the entire process group including a TERM-immune child') do
    pid_file = File.join(root, 'timeout-grandchild.pid')
    with_session(fixture, 'timeout', pid_file) do |session|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect_error(McpSession::Error, 'timed out') { session.request('echo', {}, timeout: 0.3) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      raise "timeout took #{elapsed}s" unless elapsed < 3
      raise 'server remains running' if running?(session.pid)
      raise 'TERM-immune child remains running' if running?(Integer(File.read(pid_file)))
    end
  end

  results << assert('shutdown rejects nonzero status after otherwise successful requests') do
    with_session(fixture, 'bad_exit') do |session|
      session.request('echo')
      expect_error(McpSession::Error, 'child exited unsuccessfully') { session.close }
    end
  end

  results << assert('shutdown is bounded when an exited leader leaves a child holding its pipes') do
    pid_file = File.join(root, 'shutdown-grandchild.pid')
    with_session(fixture, 'shutdown_hang', pid_file) do |session|
      expect_error(McpSession::Error, 'shutdown timed out') { session.close(timeout: 0.3) }
      raise 'TERM-immune child remains running' if running?(Integer(File.read(pid_file)))
    end
  end
end

failed = results.count(false)
puts "#{results.length} assertions; #{failed} failed"
exit(failed.zero? ? 0 : 1)
