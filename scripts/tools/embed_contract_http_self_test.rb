# frozen_string_literal: true

# Rails-free synthetic transport checks. Only disposable loopback listeners
# are contacted; no backend, model, bundle or application index is needed.
require 'socket'
require_relative '../support/embed_contract_http'

def with_response(body, code: 200, hold: false)
  server = TCPServer.new('127.0.0.1', 0)
  release = Queue.new
  requests = Queue.new
  worker = Thread.new do
    socket = server.accept
    headers = +''
    headers << socket.readpartial(1024) until headers.include?("\r\n\r\n")
    requests << headers.lines.first.strip
    release.pop if hold
    unless hold
      socket.write("HTTP/1.1 #{code} Synthetic\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end
  ensure
    socket&.close
  end
  yield "http://127.0.0.1:#{server.addr[1]}", requests
ensure
  release << true if release
  server&.close
  worker&.join(2)
  if worker&.alive?
    worker.kill
    raise 'synthetic server did not stop'
  end
  worker&.value
end

def with_http_constructor
  original = Net::HTTP.method(:new)
  observations = []
  Net::HTTP.define_singleton_method(:new) do |*args|
    http = original.call(*args)
    observations << [args, http]
    http
  end
  yield observations
ensure
  Net::HTTP.define_singleton_method(:new, original)
end

def with_proxy_env(key)
  keys = %w[HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy]
  previous = keys.to_h { |name| [name, ENV[name]] }
  keys.each { |name| ENV.delete(name) }
  ENV[key] = 'http://proxy.invalid:9'
  yield
ensure
  previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
end

def expect_error(*classes)
  begin
    yield
  rescue *classes
    return
  end
  raise "expected #{classes.join(' or ')}"
end

checks = 0
check = lambda do |name, &block|
  block.call
  checks += 1
  puts "PASS #{name}"
end

probes = {
  ollama: [:ollama_available?, '/api/tags', { 'models' => [] }, { 'models' => [{ 'name' => 'synthetic' }] }],
  qdrant: [:qdrant_available?, '/collections', { 'result' => { 'collections' => [] } },
           { 'result' => { 'collections' => [{ 'name' => 'synthetic' }] } }]
}

probes.each do |name, (method, path, empty, populated)|
  [empty, populated].each_with_index do |body, index|
    check.call("#{name} accepts #{index.zero? ? 'empty' : 'populated'} service arrays over GET") do
      with_response(JSON.generate(body)) do |url, requests|
        raise 'valid service rejected' unless EmbedContractHTTP.public_send(method, url)
        raise 'wrong probe path or method' unless requests.pop == "GET #{path} HTTP/1.1"
      end
    end
  end

  [301, 302, 307, 400, 403, 404, 407, 500, 503].each do |code|
    check.call("#{name} rejects HTTP #{code} even with a valid service body") do
      with_response(JSON.generate(empty), code: code) do |url, _|
        raise 'HTTP error/redirect accepted' if EmbedContractHTTP.public_send(method, url)
      end
    end
  end

  invalid = ['<html>models collections</html>', '{', 'null', 'true', '7', '"models collections"', '[]', '{}',
             '{"models":{},"result":{"collections":{}}}', '{"models":null,"result":{"collections":null}}',
             '{"models":"models","result":{"collections":"collections"}}',
             '{"result":[]}', '{"result":"collections"}', '{"result":null}',
             JSON.generate(empty.merge('error' => 'models collections unavailable')),
             '{"error":"models collections unavailable"}']
  invalid.each_with_index do |body, index|
    check.call("#{name} rejects invalid or error body #{index + 1}") do
      with_response(body) do |url, _|
        raise 'invalid service body accepted' if EmbedContractHTTP.public_send(method, url)
      end
    end
  end
end

%w[HTTP_PROXY http_proxy].each do |key|
  check.call("#{key} bypassed by probes, count and DELETE with bounded direct transport") do
    with_proxy_env(key) do
      with_http_constructor do |observations|
        with_response('{"models":[]}') { |url, _| raise 'probe failed' unless EmbedContractHTTP.ollama_available?(url) }
        with_response('{"result":{"collections":[]}}') do |url, _|
          raise 'probe failed' unless EmbedContractHTTP.qdrant_available?(url)
        end
        with_response('{"result":{"points_count":3}}') do |url, requests|
          raise 'count changed' unless EmbedContractHTTP.qdrant_points(url, 'synthetic') == 3
          raise 'wrong count path' unless requests.pop == 'GET /collections/synthetic HTTP/1.1'
        end
        with_response('') do |url, requests|
          raise 'cleanup failed' unless EmbedContractHTTP.delete_collection(url, 'synthetic')
          raise 'wrong cleanup path' unless requests.pop == 'DELETE /collections/synthetic HTTP/1.1'
        end
        raise 'transport not shared' unless observations.size == 4
        observations.each do |args, http|
          raise 'proxy not explicitly disabled' unless args.size == 3 && args.last.nil? && !http.proxy?
          raise 'unbounded connect/read timeouts' unless http.open_timeout == 2 && http.read_timeout == 4
          raise 'automatic retry enabled' unless http.max_retries.zero?
        end
      end
    end
  end
end

[0, 4].each do |count|
  check.call("count accepts integer #{count}") do
    with_response(JSON.generate('result' => { 'points_count' => count })) do |url, _|
      raise 'count changed' unless EmbedContractHTTP.qdrant_points(url, 'synthetic') == count
    end
  end
end

[nil, '4', 4.5, -1, true, [], {}].each do |count|
  check.call("count rejects #{count.inspect}") do
    with_response(JSON.generate('result' => { 'points_count' => count })) do |url, _|
      expect_error(EmbedContractHTTP::InvalidResponse) { EmbedContractHTTP.qdrant_points(url, 'synthetic') }
    end
  end
end

['{}', '{"result":{}}', '{"result":[]}', '{"result":null}', '{"result":4}', '[]', 'null', '{',
 '{"error":"points_count 4","result":{"points_count":4}}'].each do |body|
  check.call("count rejects malformed result #{body}") do
    with_response(body) do |url, _|
      expect_error(EmbedContractHTTP::InvalidResponse, JSON::ParserError) { EmbedContractHTTP.qdrant_points(url, 'synthetic') }
    end
  end
end

[302, 403, 404, 407, 500].each do |code|
  check.call("count and DELETE reject HTTP #{code}") do
    with_response('{"result":{"points_count":4}}', code: code) do |url, _|
      expect_error(EmbedContractHTTP::InvalidResponse) { EmbedContractHTTP.qdrant_points(url, 'synthetic') }
    end
    with_response('', code: code) do |url, _|
      raise 'cleanup error accepted' if EmbedContractHTTP.delete_collection(url, 'synthetic')
    end
  end
end

operations = [[:ollama_available?], [:qdrant_available?], [:qdrant_points, 'synthetic'], [:delete_collection, 'synthetic']]
operations.each do |method, *args|
  check.call("#{method} handles connection refusal") do
    listener = TCPServer.new('127.0.0.1', 0)
    url = "http://127.0.0.1:#{listener.addr[1]}"
    listener.close
    if method == :qdrant_points
      expect_error(Errno::ECONNREFUSED) { EmbedContractHTTP.public_send(method, url, *args) }
    else
      raise 'refused service accepted' if EmbedContractHTTP.public_send(method, url, *args)
    end
  end
  check.call("#{method} bounds a stalled response and honors timeout overrides") do
    with_http_constructor do |observations|
      with_response('', hold: true) do |url, _|
        call = -> { EmbedContractHTTP.public_send(method, url, *args, open_timeout: 0.1, read_timeout: 0.05) }
        if method == :qdrant_points
          expect_error(Net::ReadTimeout, Net::OpenTimeout) { call.call }
        else
          raise 'stalled service accepted' if call.call
        end
      end
      http = observations.fetch(0).last
      raise 'timeout overrides ignored' unless http.open_timeout == 0.1 && http.read_timeout == 0.05
    end
  end
end

puts "#{checks}/#{checks} embed HTTP cases passed"
