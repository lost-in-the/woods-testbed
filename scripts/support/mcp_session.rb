# frozen_string_literal: true

require 'json'
require 'open3'

# One held-open stdio connection. Requests are deliberately sequential, and only
# the response with the active request's ID may satisfy a request.
class McpSession
  class Error < StandardError; end
  class RequestError < Error; end
  class ToolError < Error; end

  STDERR_LIMIT = 65_536
  STDOUT_LINE_LIMIT = 16 * 1024 * 1024

  attr_reader :pid, :initialize_result

  def initialize(command:, env: {}, timeout: 30)
    raise ArgumentError, 'timeout must be positive' unless timeout.positive?
    raise ArgumentError, 'command must be a nonempty argument array' unless command.is_a?(Array) && !command.empty?

    @timeout = timeout
    @mutex = Mutex.new
    @request_mutex = Mutex.new
    @changed = ConditionVariable.new
    @stderr = +''
    @next_id = 0
    @stdin, @stdout, @stderr_io, @waiter = Open3.popen3(env, *command, pgroup: true)
    @pid = @waiter.pid
    @stdout_thread = Thread.new { drain_stdout }
    @stderr_thread = Thread.new { drain_stderr }
    [@stdout_thread, @stderr_thread].each { |thread| thread.report_on_exception = false }
    @initialize_result = request('initialize', {
      protocolVersion: '2024-11-05', capabilities: {},
      clientInfo: { name: 'woods-testbed-held-open-reader', version: '1.0' }
    })
    unless @initialize_result.is_a?(Hash) && @initialize_result['protocolVersion'].is_a?(String)
      fail_transport('initialize result has no protocolVersion')
    end
    write_message({ jsonrpc: '2.0', method: 'notifications/initialized' }, monotonic_now + @timeout)
  rescue StandardError
    @failed = true
    close(timeout: 0) if @pid
    raise
  end

  def request(method, params = {}, timeout: @timeout)
    @request_mutex.synchronize do
      raise Error, diagnostic('session is closed') if @closed
      raise ArgumentError, 'timeout must be positive' unless timeout.positive?

      deadline = monotonic_now + timeout
      id = @mutex.synchronize do
        @next_id += 1
        @waiting_id = @next_id
        @response = nil
        @next_id
      end
      write_message({ jsonrpc: '2.0', id: id, method: method, params: params }, deadline)
      response, failure = @mutex.synchronize do
        loop do
          break [nil, @protocol_error] if @protocol_error
          break [@response, nil] if @response
          break [nil, "stdout EOF before response to #{method} (id #{id})"] if @stdout_eof

          remaining = deadline - monotonic_now
          break [nil, "timed out after #{timeout}s waiting for #{method} (id #{id})"] unless remaining.positive?

          @changed.wait(@mutex, remaining)
        end
      end
      fail_transport(failure) if failure
      @mutex.synchronize { @waiting_id = nil }
      if response.key?('error')
        raise RequestError, diagnostic("#{method} JSON-RPC error: #{response['error'].inspect}")
      end

      response.fetch('result')
    end
  end

  def call_tool(name, arguments = {}, timeout: @timeout)
    result = request('tools/call', { name: name, arguments: arguments }, timeout: timeout)
    raise ToolError, diagnostic("#{name} returned a non-object result") unless result.is_a?(Hash)
    raise ToolError, diagnostic("#{name} tool error: #{result.inspect[0, 2_000]}") if result['isError']

    result
  end

  def stderr_text
    @mutex.synchronize { @stderr.dup }
  end

  # Closing stdin permits normal SDK shutdown; the deadline also covers children
  # that inherit a pipe. Always clean the group, even if its leader already exited.
  def close(timeout: 3)
    return if @closed

    @closed = true
    @stdin.close unless @stdin.closed?
    deadline = monotonic_now + timeout
    threads = [@waiter, @stdout_thread, @stderr_thread].compact
    clean = threads.all? { |thread| join_before(thread, deadline) }
    signal_group('TERM')
    unless clean
      grace = monotonic_now + 0.5
      threads.each { |thread| join_before(thread, grace) }
    end
    signal_group('KILL')
    final_deadline = monotonic_now + 1
    threads.each { |thread| join_before(thread, final_deadline) }
    [@stdout, @stderr_io].each { |io| io.close unless io.closed? }
    [@stdout_thread, @stderr_thread].compact.each { |thread| thread.kill if thread.alive? }
    @status = @waiter.value unless @waiter.alive?
    return if @failed

    failure = @mutex.synchronize { @protocol_error }
    failure ||= "shutdown timed out after #{timeout}s" unless clean
    failure ||= "child exited unsuccessfully: #{@status.inspect}" unless @status&.success?
    raise Error, diagnostic(failure) if failure

    @status
  end

  private

  def drain_stdout
    line_number = 0
    while (line = @stdout.gets(STDOUT_LINE_LIMIT + 1))
      line_number += 1
      raise Error, "stdout line #{line_number} exceeds #{STDOUT_LINE_LIMIT} bytes" if line.bytesize > STDOUT_LINE_LIMIT

      message = parse_message(line, line_number)
      next if message.key?('method') # Notifications do not consume a response ID.

      @mutex.synchronize do
        unless @waiting_id && message['id'] == @waiting_id && !@response
          raise Error, "unexpected response ID #{message['id'].inspect}; waiting for #{@waiting_id.inspect}"
        end

        @response = message
        @changed.broadcast
      end
    end
  rescue StandardError => e
    @mutex.synchronize { @protocol_error ||= "#{e.class}: #{e.message}" }
  ensure
    @mutex.synchronize do
      @stdout_eof = true
      @changed.broadcast
    end
  end

  def parse_message(line, number)
    message = JSON.parse(line)
    unless message.is_a?(Hash) && message['jsonrpc'] == '2.0'
      raise Error, "stdout line #{number} is not a JSON-RPC 2.0 object"
    end

    if message.key?('method')
      unless message['method'].is_a?(String) && !message.key?('id') &&
             !message.key?('result') && !message.key?('error') &&
             (!message.key?('params') || message['params'].is_a?(Hash) || message['params'].is_a?(Array))
        raise Error, "stdout line #{number} is not a valid notification"
      end
    else
      unless (message['id'].is_a?(Integer) || message['id'].is_a?(String)) &&
             (message.key?('result') ^ message.key?('error'))
        raise Error, "stdout line #{number} is not a valid response"
      end
      if message.key?('error')
        error = message['error']
        unless error.is_a?(Hash) && error['code'].is_a?(Integer) && error['message'].is_a?(String)
          raise Error, "stdout line #{number} has an invalid error object"
        end
      end
    end
    message
  rescue JSON::ParserError
    raise Error, "non-JSON stdout line #{number}: #{line[0, 200].inspect}"
  end

  def drain_stderr
    loop do
      chunk = @stderr_io.readpartial(4096)
      @mutex.synchronize do
        @stderr << chunk
        @stderr = @stderr.byteslice(-STDERR_LIMIT, STDERR_LIMIT) if @stderr.bytesize > STDERR_LIMIT
      end
    end
  rescue EOFError, IOError
    nil
  end

  def write_message(message, deadline)
    bytes = (JSON.generate(message) + "\n").b
    until bytes.empty?
      remaining = deadline - monotonic_now
      fail_transport('timed out writing request to stdin') unless remaining.positive?
      written = @stdin.write_nonblock(bytes, exception: false)
      if written == :wait_writable
        IO.select(nil, [@stdin], nil, remaining)
      else
        bytes = bytes.byteslice(written, bytes.bytesize - written)
      end
    end
  rescue IOError, SystemCallError => e
    fail_transport("could not write request: #{e.class}: #{e.message}")
  end

  def fail_transport(message)
    @failed = true
    close(timeout: 0)
    raise Error, diagnostic(message)
  end

  def diagnostic(message)
    stderr = stderr_text
    "#{message} (MCP pid #{@pid}; stderr tail: #{stderr[-4_096, 4_096] || stderr})"
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def join_before(thread, deadline)
    remaining = deadline - monotonic_now
    thread.join(remaining) if remaining.positive?
    !thread.alive?
  end

  def signal_group(signal)
    Process.kill(signal, -@pid)
  rescue Errno::ESRCH
    nil
  end
end
