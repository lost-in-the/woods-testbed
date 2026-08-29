# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rbconfig'
require 'tmpdir'
require_relative '../support/mcp_executable_exchange'

results = []

def assert(name)
  yield
  puts "PASS #{name}"
  true
rescue StandardError => e
  puts "FAIL #{name}: #{e.class}: #{e.message}"
  false
end

def write_child(root, name, source)
  path = File.join(root, "#{name}.rb")
  File.write(path, source)
  path
end

def run_child(path, timeout: 1)
  McpExecutableExchange.json_rpc_exchange(
    command: [RbConfig.ruby, path],
    index_dir: Dir.pwd,
    requests: [{ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }],
    timeout: timeout,
    env: {}
  )
end

Dir.mktmpdir('mcp-executable-exchange-self-test') do |root|
  clean_child = write_child(root, 'clean', <<~'RUBY')
    require 'json'
    STDOUT.puts(JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'result' => { 'ok' => true }))
    STDOUT.flush
    exit 0
  RUBY

  blank_child = write_child(root, 'blank', <<~'RUBY')
    STDOUT.puts
    STDOUT.flush
    exit 0
  RUBY

  exit_42_child = write_child(root, 'exit_42', <<~'RUBY')
    require 'json'
    STDOUT.puts(JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'result' => { 'ok' => true }))
    STDOUT.flush
    exit 42
  RUBY

  hanging_child = write_child(root, 'hanging', <<~'RUBY')
    require 'json'
    STDOUT.puts(JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'result' => { 'ok' => true }))
    STDOUT.flush
    sleep 10
  RUBY

  grandchild_hang = write_child(root, 'grandchild_hang', <<~'RUBY')
    require 'json'
    fork do
      trap('TERM', 'IGNORE')
      sleep 10
    end
    STDOUT.puts(JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'result' => { 'ok' => true }))
    STDOUT.flush
    exit 0
  RUBY

  results << assert('clean status-0 control passes protocol and exit validation') do
    result = run_child(clean_child)
    messages = McpExecutableExchange.validate_successful_exchange!(result, timeout: 1)
    raise "wrong messages: #{messages.inspect}" unless messages.one? && messages.first['id'] == 1
  end

  results << assert('blank stdout is rejected as a protocol violation') do
    result = run_child(blank_child)
    begin
      McpExecutableExchange.parse_protocol_stdout!(result)
    rescue McpExecutableExchange::ValidationError => e
      raise unless e.message.include?('blank line')
      next
    end
    raise 'blank stdout passed validation'
  end

  results << assert('valid JSON-RPC followed by exit 42 still fails exchange validation') do
    result = run_child(exit_42_child)
    McpExecutableExchange.parse_protocol_stdout!(result)
    begin
      McpExecutableExchange.validate_clean_exit!(result, timeout: 1)
    rescue McpExecutableExchange::ValidationError => e
      raise unless e.message.include?('status 42')
      next
    end
    raise 'non-zero child status passed validation'
  end

  results << assert('post-response hang trips the watchdog') do
    result = run_child(hanging_child, timeout: 1)
    begin
      McpExecutableExchange.validate_successful_exchange!(result, timeout: 1)
    rescue McpExecutableExchange::ValidationError => e
      raise unless e.message.include?('watchdog')
      next
    end
    raise 'hanging child passed validation'
  end

  results << assert('TERM-immune grandchild holding stdout cannot hang the exchange') do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = run_child(grandchild_hang, timeout: 0.5)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    raise "exchange remained blocked for #{elapsed.round(2)}s" if elapsed > 3

    begin
      McpExecutableExchange.validate_successful_exchange!(result, timeout: 0.5)
    rescue McpExecutableExchange::ValidationError => e
      raise unless e.message.include?('watchdog')
      next
    end
    raise 'grandchild-held stdout passed validation'
  end
end

failed = results.count(false)
exit(failed.zero? ? 0 : 1)
