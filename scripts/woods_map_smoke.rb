# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_map_smoke.rb
# after:     bin/rails woods:extract
#
# Smoke-tests the Woods Map engine (lost-in-the/woods-map) mounted at /woods
# against the index the variant just published (woods-testbed#38): the status
# page, a unit page whose code view links a resolved reference, name search,
# the impact page's blast radius, and the blog scenario's seeded bug, the
# instance variable MailingListMailer's template reads and nothing assigns.
# Variants without the engine, or without the blog scenario, skip what they
# lack. Requests go through the app's own Rack stack from loopback, with the
# compose environment's WOODS_MAP_TOKEN as a bearer token when one is set.

unless defined?(WoodsMap::Engine)
  puts 'SKIP  Woods Map is not mounted in this variant'
  exit 0
end

results = []

def assert(name, &block)
  block.call
  puts "  PASS  #{name}"
  true
rescue StandardError => e
  puts "  FAIL  #{name}: #{e.class}: #{e.message}"
  false
end

session = Rack::MockRequest.new(Rails.application)
headers = { 'REMOTE_ADDR' => '127.0.0.1', 'HTTP_HOST' => 'localhost' }
headers['HTTP_AUTHORIZATION'] = "Bearer #{ENV['WOODS_MAP_TOKEN']}" if ENV['WOODS_MAP_TOKEN'].to_s != ''

fetch = lambda do |path|
  response = session.get(path, headers)
  raise "#{path} answered #{response.status}" unless response.status == 200

  response.body
end

expect_in = lambda do |body, *needles|
  missing = needles.reject { |needle| body.include?(needle) }
  raise "missing #{missing.map(&:inspect).join(', ')}" if missing.any?
end

blog = defined?(MailingListMailer)

puts '=== Woods Map smoke ==='
puts "Rails:       #{Rails.version}"
puts "Woods Map:   #{WoodsMap::VERSION}"
puts "Index:       #{WoodsMap.configuration.index_path}"
puts "Blog:        #{blog ? 'present' : 'absent, its checks skip'}"
puts

results << assert('the status page reports the published generation') do
  expect_in.call(fetch.call('/woods'), 'gen ')
end

results << assert('a unit page renders the code view and links a resolved reference') do
  body = fetch.call('/woods/units/controller/UsersController')
  expect_in.call(body, 'class="cv codeview"', 'href="/woods/units/model/User"')
end

results << assert('name search finds a unit') do
  expect_in.call(fetch.call('/woods/search?q=user&in=name'), 'href="/woods/units/model/User"')
end

results << assert('the impact page reads the blast radius of a focus') do
  expect_in.call(fetch.call('/woods/impact?focus=User&depth=1'), 'Blast radius')
end

if blog
  results << assert('the Post unit page carries its Taggable concern and lifecycle') do
    expect_in.call(fetch.call('/woods/units/model/Post/lifecycle'), 'set_slug', 'notify_subscribers')
  end

  results << assert('the passage of MailingListMailer#new_post flags @preferences, read and never assigned') do
    body = fetch.call('/woods/units/mailer/MailingListMailer/passage?action_name=new_post')
    expect_in.call(body, '@preferences', 'read, never assigned')
  end
end

puts
passed = results.count(true)
puts "#{passed}/#{results.size} passed"
exit(passed == results.size ? 0 : 1)
