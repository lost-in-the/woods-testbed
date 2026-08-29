# frozen_string_literal: true

require 'json'
require 'open3'

module McpExecutableExchange
  Result = Struct.new(:stdout_lines, :stderr_text, :status, :timed_out, :parsed_messages, keyword_init: true)

  class ValidationError < StandardError; end

  module_function

  def json_rpc_exchange(command:, index_dir:, requests:, timeout:, env: {})
    stdout_lines = []
    stderr_chunks = []
    timed_out = false
    child_status = nil
    command_args = Array(command) + [index_dir]

    Open3.popen3(env, *command_args, pgroup: true) do |stdin, stdout, stderr, wait_thr|
      deadline = monotonic_now + timeout
      stdout_drain = Thread.new { stdout.each_line { |line| stdout_lines << line.chomp } }
      stderr_drain = Thread.new { stderr_chunks << stderr.read }
      stdout_drain.report_on_exception = false
      stderr_drain.report_on_exception = false

      requests.each { |request| stdin.puts(JSON.generate(request)) }
      stdin.close

      completed = [wait_thr, stdout_drain, stderr_drain].all? do |thread|
        join_before_deadline(thread, deadline)
      end
      unless completed
        timed_out = true
        terminate_process_group(wait_thr.pid, wait_thr, stdout_drain, stderr_drain)
      end

      child_status = wait_thr.value unless wait_thr.alive?
    end

    Result.new(stdout_lines: stdout_lines, stderr_text: stderr_chunks.join,
               status: child_status, timed_out: timed_out, parsed_messages: [])
  end

  def parse_protocol_stdout!(result)
    if result.stdout_lines.empty?
      raise ValidationError, "no stdout at all (stderr: #{result.stderr_text[0, 300].inspect})"
    end

    if result.stdout_lines.any? { |line| line.strip.empty? }
      raise ValidationError, 'blank line on stdout — not a JSON-RPC message (protocol violation)'
    end

    parsed = result.stdout_lines.each_with_index.map do |line, index|
      parse_json_rpc_line(line, index)
    end

    bad = parsed.reject { |message| message['jsonrpc'] == '2.0' }
    unless bad.empty?
      raise ValidationError, "messages without jsonrpc 2.0 envelope: #{bad.inspect}"
    end

    result.parsed_messages = parsed
  end

  def validate_clean_exit!(result, timeout:)
    if result.timed_out
      raise ValidationError, "the watchdog killed the child (no clean exit within #{timeout}s)"
    end

    status = result.status
    raise ValidationError, 'child status was not captured' unless status

    if status.exited?
      raise ValidationError, "child exited with status #{status.exitstatus}" unless status.exitstatus.zero?
    else
      raise ValidationError, "child was killed by signal #{status.termsig}"
    end
  end

  def validate_successful_exchange!(result, timeout:)
    parse_protocol_stdout!(result)
    validate_clean_exit!(result, timeout: timeout)
    result.parsed_messages
  end

  def response_for!(messages, id)
    response = messages.find { |message| message['id'] == id }
    raise ValidationError, "no response with id #{id.inspect}" unless response

    response
  end

  def assert_tool_success!(response, tool_name:)
    result = response['result'] || {}
    raise ValidationError, "#{tool_name} errored at the JSON-RPC layer: #{response['error'].inspect}" if response['error']
    raise ValidationError, "#{tool_name} result is not a Hash: #{result.inspect}" unless result.is_a?(Hash)
    return result unless result['isError']

    code = result.dig('_meta', 'error_code') || result.dig('structuredContent', 'error_code')
    text = result.dig('content', 0, 'text').to_s[0, 200]
    raise ValidationError, "#{tool_name} tool error (#{code}): #{text.inspect}"
  end

  def join_before_deadline(thread, deadline)
    remaining = deadline - monotonic_now
    thread.join(remaining) if remaining.positive?
    !thread.alive?
  end
  private_class_method :join_before_deadline

  def terminate_process_group(pid, *threads)
    kill_process_group(pid, 'TERM')
    grace_deadline = monotonic_now + 1
    threads.each { |thread| join_before_deadline(thread, grace_deadline) }
    # Always address the process group, even if its direct child has exited:
    # a TERM-immune grandchild may still own stdout/stderr and keep a drain
    # thread blocked forever.
    kill_process_group(pid, 'KILL')
    threads.each { |thread| thread.join(5) }
  end
  private_class_method :terminate_process_group

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
  private_class_method :monotonic_now

  def kill_process_group(pid, signal)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
  private_class_method :kill_process_group

  def parse_json_rpc_line(line, index)
    parsed = JSON.parse(line)
    raise ValidationError, "stdout line #{index + 1} is not a JSON object: #{line[0, 120].inspect}" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError => e
    raise ValidationError, "non-JSON stdout line #{index + 1}: #{line[0, 120].inspect} (#{e.class})"
  end
  private_class_method :parse_json_rpc_line
end
