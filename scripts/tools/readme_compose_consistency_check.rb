# frozen_string_literal: true

require 'yaml'

README_PATH = 'README.md'
COMPOSE_PATH = 'docker-compose.yml'

readme = File.read(README_PATH, encoding: 'UTF-8')
compose = YAML.safe_load(File.read(COMPOSE_PATH, encoding: 'UTF-8'), aliases: true)

readme_variants = {}
readme.scan(/^\| `apps\/([^`]+)` \| [^|]+ \| [^|]+ \| ([0-9]+) \| `([^`]+)` \|$/) do |variant, port, container|
  readme_variants[variant] = { 'port' => port, 'container' => container }
end

compose_variants = {}
compose.fetch('services').each do |service, config|
  context = config.dig('build', 'context').to_s
  next unless context.start_with?('./apps/')

  variant = context.delete_prefix('./apps/')
  port = Array(config['ports']).first.to_s
  match = port.match(/\A\$\{(?<env>[A-Z0-9_]+):-(?<default>[0-9]+)\}:3000\z/)
  abort "#{COMPOSE_PATH}: #{service} has unexpected port mapping #{port.inspect}" unless match

  compose_variants[variant] = {
    'port' => match[:default],
    'container' => config.fetch('container_name'),
    'env' => match[:env]
  }
end

missing_from_readme = compose_variants.keys - readme_variants.keys
extra_in_readme = readme_variants.keys - compose_variants.keys
abort "#{README_PATH}: missing variant rows for #{missing_from_readme.join(', ')}" unless missing_from_readme.empty?
abort "#{README_PATH}: rows without compose services: #{extra_in_readme.join(', ')}" unless extra_in_readme.empty?

compose_variants.each do |variant, expected|
  actual = readme_variants.fetch(variant)
  unless actual['port'] == expected['port']
    abort "#{README_PATH}: #{variant} documents port #{actual['port']}, compose default is #{expected['port']}"
  end

  next if actual['container'] == expected['container']

  abort "#{README_PATH}: #{variant} documents container #{actual['container']}, compose uses #{expected['container']}"
end

unless readme.include?('RAILS_60_MYSQL_PORT')
  abort "#{README_PATH}: missing RAILS_60_MYSQL_PORT port override guidance"
end

puts "README/Compose variants OK: #{compose_variants.keys.sort.join(', ')}"
