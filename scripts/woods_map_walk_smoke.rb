# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_map_walk_smoke.rb
# after:     bin/rails woods:extract
#
# Walks the two Woods Map design-study scenarios (scripts/support/
# woods_map_walks.json) by clicking only: every step's link must exist on
# the page the previous step landed on, outside the file-tree sheet, and the
# page it leads to must answer 200 with the expected heading and text. The
# pages are the server-rendered HTML, so this is the JavaScript-disabled
# path of the M1 exit criterion; scripts/tools/woods_map_click_walk.mjs walks
# the same steps in a browser with JavaScript on and off and runs axe.
# Variants without the engine, or without a scenario's units, skip it.

require 'json'
require 'nokogiri'

unless defined?(WoodsMap::Engine)
  puts 'SKIP  Woods Map is not mounted in this variant'
  exit 0
end

WALKS = JSON.parse(File.read(File.expand_path('support/woods_map_walks.json', __dir__), encoding: 'UTF-8'))
HEADERS = { 'REMOTE_ADDR' => '127.0.0.1', 'HTTP_HOST' => 'localhost', 'HTTP_ACCEPT' => 'text/html' }.tap do |h|
  h['HTTP_AUTHORIZATION'] = "Bearer #{ENV['WOODS_MAP_TOKEN']}" if ENV['WOODS_MAP_TOKEN'].to_s != ''
end

session = Rack::MockRequest.new(Rails.application)

# @return [Array(Integer, String, String)] status, final path, body
fetch = lambda do |path|
  3.times do
    response = session.get(path, HEADERS)
    return [response.status, path, response.body] unless (300..399).cover?(response.status)

    path = URI(response.location).request_uri
  end
  raise "#{path}: too many redirects"
end

parse = ->(body) { Nokogiri::HTML5(body.dup.force_encoding('UTF-8')) }
# Links a reader can click: everything but the file-tree sheet.
clickable = ->(doc) { doc.css('a[href]').reject { |a| a.ancestors('.sheet').any? }.map { |a| a['href'] } }
visible_text = lambda do |doc|
  copy = doc.dup
  copy.css('.sheet, script, style, template').each(&:remove)
  copy.text.gsub(/\s+/, ' ')
end

present = lambda do |requires|
  WoodsMap::Repository.open(WoodsMap.configuration.index_path) do |repository|
    requires.all? { |identifier, type| repository.unit(identifier, type: type) }
  end
end

# What a step's "needs" names: a step that needs a capability this variant
# lacks is skipped; one whose capabilities are all there must find its link.
# The author filter (woods-map#92) needs a commit table in the published index
# and a Woods Map that has the filter.
capabilities = WoodsMap::Repository.open(WoodsMap.configuration.index_path) do |repository|
  table = repository.respond_to?(:commit_table_state) && repository.commit_table_state == :available
  table ? ['commit_table'] : []
end
capabilities << 'author_filter' if WoodsMap::HistoryView.method_defined?(:author)

failures = 0
passed = 0
puts '=== Woods Map click-only walks (server-rendered, JavaScript off) ==='
puts "Rails:       #{Rails.version}"
puts "Woods Map:   #{WoodsMap::VERSION}"
puts

WALKS.fetch('scenarios').each do |scenario|
  puts "--- Scenario #{scenario['id']}: #{scenario['title']}"
  unless present.call(scenario.fetch('requires'))
    puts "  SKIP  the index lacks #{scenario['requires'].map(&:first).join(', ')}"
    next
  end

  doc = nil
  here = nil
  scenario.fetch('steps').each do |step|
    label = "step #{step['step']}"
    target = step['start'] || step['click']
    missing_capabilities = Array(step['needs']) - capabilities
    if missing_capabilities.any?
      puts "  SKIP  #{label}: no #{missing_capabilities.map { |c| c.tr('_', ' ') }.join(', ')} here (#{step['optional']})"
      next
    end
    if step['click_prefix']
      target = doc && clickable.call(doc).find { |href| href.start_with?(step['click_prefix']) }
      if target.nil? && step['needs']
        failures += 1
        puts "  FAIL  #{label}: no link starting #{step['click_prefix']} on #{here}"
        break
      end
      unless target
        puts "  SKIP  #{label}: no link starting #{step['click_prefix']} on #{here} (#{step['optional']})"
        next
      end
    elsif step['click'] && !clickable.call(doc).include?(target)
      failures += 1
      puts "  FAIL  #{label}: no link to #{target} on #{here}"
      break
    end

    status, landed, body = fetch.call(target.split('#').first)
    page = parse.call(body)
    heading = page.at_css('h1')&.text.to_s.gsub(/\s+/, ' ')
    text = visible_text.call(page)
    missing = Array(step['text']).reject { |needle| text.include?(needle) }
    problems = []
    problems << "answered #{status}" unless status == 200
    problems << "h1 #{heading.inspect} lacks #{step['h1'].inspect}" if step['h1'] && !heading.include?(step['h1'])
    problems << "missing #{missing.map(&:inspect).join(', ')}" if missing.any?
    if problems.any?
      failures += 1
      puts "  FAIL  #{label}: #{target}: #{problems.join('; ')}"
      break
    end

    passed += 1
    puts "  PASS  #{label}: #{step['start'] ? 'open' : 'click'} #{target}"
    doc = page
    here = landed
  end
  Array(scenario['not_walked']).each { |note| puts "  NOTE  #{note}" }
end

puts
puts "#{passed} steps passed, #{failures} failed"
exit(failures.zero? ? 0 : 1)
