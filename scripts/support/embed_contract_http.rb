# frozen_string_literal: true

require 'json'
require 'net/http'

# Out-of-band checks for the embed smoke. They take the same proxy path as
# the gem's own Ollama and Qdrant clients (Net::HTTP with the environment's
# proxy settings, if any), so a probe and the gem share one route to the
# service instead of the probe going direct while the gem goes through a
# proxy. The response checks reject an intermediary's answer (a proxy's own
# page is not a service object with the expected keys), and no count or
# cleanup request waits indefinitely.
module EmbedContractHTTP
  class InvalidResponse < StandardError; end

  module_function

  def request(url, path, method: :get, open_timeout: 2, read_timeout: 4)
    uri = URI("#{url}#{path}")
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = open_timeout
    http.read_timeout = read_timeout
    http.max_retries = 0
    request_class = { get: Net::HTTP::Get, delete: Net::HTTP::Delete }.fetch(method)
    http.start { |connection| connection.request(request_class.new(uri)) }
  end

  def json(url, path, **timeouts)
    response = request(url, path, **timeouts)
    raise InvalidResponse, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    body = JSON.parse(response.body)
    raise InvalidResponse, 'expected a service object without an error' unless body.is_a?(Hash) && !body.key?('error')

    body
  end

  def ollama_available?(url, **timeouts)
    json(url, '/api/tags', **timeouts)['models'].is_a?(Array)
  rescue StandardError
    false
  end

  def qdrant_available?(url, **timeouts)
    result = json(url, '/collections', **timeouts)['result']
    result.is_a?(Hash) && result['collections'].is_a?(Array)
  rescue StandardError
    false
  end

  def qdrant_points(url, collection, **timeouts)
    result = json(url, "/collections/#{collection}", **timeouts)['result']
    count = result['points_count'] if result.is_a?(Hash)
    raise InvalidResponse, 'expected a nonnegative integer points_count' unless count.is_a?(Integer) && count >= 0

    count
  end

  def delete_collection(url, collection, **timeouts)
    request(url, "/collections/#{collection}", method: :delete, **timeouts).is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end
end
