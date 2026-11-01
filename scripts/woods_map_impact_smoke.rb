# frozen_string_literal: true

# Strict, opt-in Rails runner acceptance for woods-testbed#38. Required ENV:
#   WOODS_MAP_IMPACT_FROM=gen:1
#   WOODS_MAP_IMPACT_TO=gen:2
#   WOODS_MAP_IMPACT_TEMPLATE=app/views/posts/_card.html.erb
#   WOODS_MAP_IMPACT_REPORT_ID=<64 lowercase hex characters printed by woods:impact>
#   WOODS_MAP_IMPACT_MARKDOWN=/absolute/path/to/impact.md
# Run from inside the app container (no positional arguments):
#   timeout --kill-after=5s 120s bin/rails runner script/shared/woods_map_impact_smoke.rb
# Optional WOODS_MAP_IMPACT_TIMEOUT=1..60 seconds; default 60 after runner load.
# The outer deadline covers Rails boot; keep it inside any future live CI
# container invocation as well as around a direct run of this command.
#
# Prepare OUTSIDE this script: publish base, make a controlled template source
# change, run woods:incremental with app-relative CHANGED_FILES, publish head,
# then FORMAT=markdown timeout --kill-after=5s 120s bin/rails \
#   'woods:impact[gen:1,gen:2]' > /tmp/impact.md.
# Pass the saved report ID printed to stderr. Both payloads AND that task's
# saved report must remain in WoodsMap.configuration.index_path. Trusted task
# invocation evidence belongs to preparation: report IDs and manifest checksums
# do not authenticate all report content as output of that same index. Head must
# still be current: Map's ?since=base compares to now. Use explicit gen:N (up
# to nine digits); SHA/now selectors and identical/reversed ranges are refused.
# The existing template must have a complete source diff with a visible line
# anchor (an added/replaced line or a deletion after a retained line). Commas
# are refused because Map focus URLs split identifiers on commas.
#
# Reads the real Woods Store, pure LineDiff and Markdown renderer. Never calls
# Task#run or a replacement report generator. Exercises the mounted /woods range, its copy
# focus URL, and the typed template's ?since= link through the app's Rack stack.
# Uses loopback and optional WOODS_MAP_TOKEN bearer auth; needs no AI provider.
# No successful skips, source writes, git, extraction, cleanup or publication.
# Fixed bounds: <=5,000 units per endpoint, 2 MiB saved JSON, 64 KiB Markdown,
# 8 MiB per HTML response, two requests. Map performs its normal bounded Woods
# range read; run on a quiescent, bounded index before unrelated publishing smokes.
# The 5,000-unit smoke policy excludes the ~10,000-unit Canopy large preset;
# No live Rails 8.0, 6.0, 7.2 or bounded Canopy acceptance is established here.
# CI/docs/mount integration is separate: the general scripts/*.rb loop must
# explicitly arrange these inputs or exclude this opt-in smoke.

require 'digest'
require 'json'
require 'pathname'
require 'rbconfig'
require 'uri'
require 'timeout'

class WoodsMapImpactSmoke
  class Failure < StandardError; end

  STEPS = 8
  MAX_UNITS = 5_000
  MAX_REPORT_BYTES = 2 * 1024 * 1024
  MAX_MARKDOWN_BYTES = 64 * 1024
  MAX_HTML_BYTES = 8 * 1024 * 1024
  ARRAYS = %w[changed affected flows tables templates risks tests commits unknowns].freeze
  # Schema-1 range producer values. Bounded/partial evidence remains explicit.
  COVERAGE = {
    'complete' => [false], 'diff' => ['retained_payloads'], 'snapshot_facets' => ['unbound'],
    'affected' => %w[bounded partial], 'flows' => %w[bounded partial],
    'tables' => ['partial'], 'templates' => ['partial'], 'risks' => ['partial'], 'tests' => ['partial'],
    'commits' => ['not_computed'], 'focus' => ['not_computed']
  }.freeze
  MOUNT = '/woods'

  def run
    @passed = 0
    puts '=== Woods Map retained impact smoke (strict) ==='
    seconds = ENV.fetch('WOODS_MAP_IMPACT_TIMEOUT', '60')
    check(seconds.match?(/\A(?:[1-9]|[1-5]\d|60)\z/), 'WOODS_MAP_IMPACT_TIMEOUT must be an integer from 1 to 60 seconds')
    # Default Timeout::Error escapes the whole block even through library rescues.
    # It covers Repository.open and both blocking PublishedIndex constructors.
    Timeout.timeout(seconds.to_i) do
      step('explicit selectors and artifact paths') { inputs }
      step('loaded Rails/Woods/Map capabilities and index cache') { runtime }
      WoodsMap::Repository.open(@index) do |repository|
        @repository = repository
        step('retained base/head and exact typed template') { retained_range }
        step('saved report contract and retained provenance') { saved_report }
        step('real Woods task Markdown contract') { markdown }
        step('mounted Map range, typed change and focus URL') { range_page }
        step('typed template since range and source highlight') { since_page }
        step('published head remained current in the same index') { stable_head }
      end
    end
    puts "#{@passed}/#{STEPS} steps passed; 0 skipped; 2 Rack requests"
    0
  rescue Failure, LoadError, StandardError => e
    # Library errors can contain source-controlled data, response bodies, paths
    # or credentials. Only our own diagnostics are printed, never raw exceptions.
    detail = if e.is_a?(Timeout::Error)
               'Read-only smoke deadline exceeded; verify quiescent retained manifest locks and the Map stack, then rerun'
             elsif e.is_a?(Failure)
               e.message
             else
               "#{e.class}; verify the bundle, readable retained cache and Map mount"
             end
    puts "  FAIL  #{@step || 'setup'}: #{detail}"
    puts "#{@passed}/#{STEPS} steps passed; 1 failed; remaining steps not run; 0 skipped"
    1
  ensure
    @before&.close
    @after&.close
  end

  private

  def check(condition, message)
    raise Failure, message unless condition
  end

  def step(name)
    @step = name
    yield
    @passed += 1
    puts "  PASS  #{name}"
  end

  def required(name)
    value = ENV[name]
    check(value.is_a?(String) && !value.empty? && value.valid_encoding? && !value.match?(/[\p{Cc}]/),
          "Set #{name}; see the required ENV and preparation recipe in this script's header")
    value
  end

  def inputs
    check(ARGV.empty?, 'Use the documented WOODS_MAP_IMPACT_* ENV inputs, with no positional arguments')
    @from = required('WOODS_MAP_IMPACT_FROM')
    @to = required('WOODS_MAP_IMPACT_TO')
    check([@from, @to].all? { |value| value.match?(/\Agen:[1-9]\d{0,8}\z/) },
          'FROM and TO must be explicit gen:N selectors (1..999999999); retain both payloads, never use now or SHA aliases')
    check(@from != @to, 'FROM and TO must select distinct retained generations')
    @base = @from.delete_prefix('gen:').to_i
    @head = @to.delete_prefix('gen:').to_i
    check(@base < @head, 'FROM must be older than TO; supply the retained base then the published head')
    @template = required('WOODS_MAP_IMPACT_TEMPLATE')
    parts = @template.split('/', -1)
    check(@template.start_with?('app/views/') && parts.size > 2 &&
          parts.none? { |part| ['', '.', '..'].include?(part) } && !@template.include?('\\'),
          'TEMPLATE must be an exact app-relative app/views/... path, without traversal or backslashes')
    check(!@template.include?(','), 'TEMPLATE cannot contain a comma: Map focus URLs use comma-separated identifiers')
    @identifier = @template.delete_prefix('app/views/')
    @id = required('WOODS_MAP_IMPACT_REPORT_ID')
    check(@id.match?(/\A[0-9a-f]{64}\z/), 'REPORT_ID must be the 64 lowercase hex ID printed by the real woods:impact task')
    @markdown_path = required('WOODS_MAP_IMPACT_MARKDOWN')
    check(Pathname.new(@markdown_path).absolute?, 'Markdown path must be absolute; capture only woods:impact stdout there')
    @captured_markdown = bounded_file(@markdown_path, MAX_MARKDOWN_BYTES, 'Markdown artifact')
  end

  def bounded_file(path, limit, label)
    File.open(path, File::RDONLY | File::NONBLOCK) do |file|
      check(file.stat.file? && file.stat.size.between?(1, limit), "#{label} must be a nonempty regular file of at most #{limit} bytes")
      bytes = file.read(limit + 1).to_s.force_encoding(Encoding::UTF_8)
      check(bytes.bytesize <= limit && bytes.valid_encoding?, "#{label} must be bounded, valid UTF-8")
      bytes
    end
  rescue SystemCallError, IOError
    raise Failure, "#{label} is missing or unreadable; run the real woods:impact task and retain its artifacts"
  end

  def runtime
    check(defined?(Rails.application) && defined?(WoodsMap::Engine),
          'Rails and Woods Map must be loaded and mounted at /woods; run this through that app\'s Rails runner')
    require 'woods/published_index' unless defined?(Woods::PublishedIndex)
    require 'woods/impact/store'
    require 'woods/impact/renderers' # a leaf renderer may already define this namespace
    require 'woods/impact/line_diff'
    require 'nokogiri'
    require 'rack/mock' unless defined?(Rack::MockRequest)
    check(defined?(Woods::VERSION) && defined?(WoodsMap::VERSION), 'Loaded Woods and Map must expose their versions')
    configured = WoodsMap.configuration.index_path.to_s
    check(!configured.empty? && !configured.match?(/[\p{Cc}]/) && File.directory?(configured),
          'Map index cache is missing; restore/publish both retained payloads in its configured index before running')
    @index = File.realpath(configured)
    check(File.file?(File.join(@index, 'generation.json')), 'Map index cache has no generation pointer; restore a numbered published index')
    puts "Rails:       #{Rails.version} (#{loaded_at(Rails.method(:version))})"
    puts "Ruby:        #{RUBY_VERSION} (#{RbConfig.ruby})"
    puts "Woods:       #{Woods::VERSION} (#{Woods.const_source_location(:VERSION)&.first})"
    puts "Woods Map:   #{WoodsMap::VERSION} (#{WoodsMap.const_source_location(:VERSION)&.first})"
    puts "Store:       #{loaded_at(Woods::Impact::Store.instance_method(:read))}"
    puts "Renderer:    #{loaded_at(Woods::Impact::Renderers.method(:markdown))}"
    puts "Map reader:  #{loaded_at(WoodsMap::Repository.method(:open))}"
    puts "Index real:  #{@index}"
    puts "Range:       #{@from} (#{@base}) -> #{@to} (#{@head})"
    puts "Template:    #{@template} [view_template]"
    puts "Report ID:   #{@id}"
  rescue LoadError
    raise Failure, 'Required Woods Store/Renderers/LineDiff, Rack or Nokogiri unavailable; use the app bundle with Woods Map mounted'
  end

  def loaded_at(method)
    path = method.source_location&.first
    path && File.file?(path) ? File.realpath(path) : (path || 'unavailable')
  end

  def retained_range
    check(File.realpath(@repository.index_dir.to_s) == @index, 'Map repository opened a different index')
    check(@repository.generation_number == @head, 'TO must be the current Map generation: ?since= compares base to now; freeze publication or select the current head')
    available = Woods::PublishedIndex.available_generations(@index)
    check([@base, @head].all? { |number| available.include?(number) },
          'Both generations must be retained in the same index; restore the base cache if pruned and retain the published head')
    @before = Woods::PublishedIndex.new(@index, generation: @base)
    @after = Woods::PublishedIndex.new(@index, generation: @head)
    [@before, @after].zip([@base, @head]).each do |reader, number|
      check(reader.generation_number == number, 'Retained reader returned another generation')
      manifest = reader.manifest
      check(manifest.is_a?(Hash), 'Retained manifest must be an object; restore an intact cache')
      count = manifest['total_units']
      check(count.is_a?(Integer) && count.between?(1, MAX_UNITS), "Retained index exceeds the #{MAX_UNITS} unit limit or lacks a valid total; use a bounded fixture index")
      counts = manifest['counts']
      check(counts.is_a?(Hash) && counts.values.all? { |value| value.is_a?(Integer) && value >= 0 } && counts.values.sum == count,
            'Retained manifest counts are incomplete or inconsistent; restore an intact published cache')
      unit = reader.unit(@identifier, type: 'view_template')
      check(unit.is_a?(Hash) && unit.values_at('identifier', 'type') == [@identifier, 'view_template'] &&
            unit['source_code'].is_a?(String) && unit['metadata'].is_a?(Hash) && unit['dependencies'].is_a?(Array),
            'Both retained template units need exact typed identity, source_code, metadata and dependencies; restore complete payloads')
      check(unit['file_path'] == @template, 'Retained template file_path does not match TEMPLATE; use the exact app-relative published path')
    end
    owners = @repository.file_owners(@template)
    check(owners.is_a?(Array) && owners.any? { |owner| owner.values_at('identifier', 'type') == [@identifier, 'view_template'] },
          'Map has no matching typed owner for TEMPLATE in the current file map; publish the expected template')
    current = @repository.unit(@identifier, type: 'view_template')
    check(current == @after.unit(@identifier, type: 'view_template'), 'Map and retained head returned different template units')
  end

  def saved_report
    store = Woods::Impact::Store.new(@index)
    bounded_file(store.path_for(@id), MAX_REPORT_BYTES, 'saved report')
    begin
      @data = JSON.parse(store.read(@id))
    rescue StandardError
      raise Failure, 'The saved report is missing, unsafe, corrupt or unsupported; rerun woods:impact for this retained range in the Map index'
    end
    check(@data.is_a?(Hash) && @data['schema_version'] == 1, 'Unsupported saved report schema; require Woods impact schema 1')
    check(@data['parameters'].is_a?(Hash) && @data['parameters']['mode'] == 'range', 'Saved report must be a range report, not focus mode')
    ARRAYS.each do |key|
      check(@data[key].is_a?(Array) && @data[key].all? { |entry| entry.is_a?(Hash) }, "Malformed report #{key}; restore a complete task-generated report")
    end
    coverage = @data['coverage']
    check(coverage.is_a?(Hash) && COVERAGE.all? { |key, values| coverage.key?(key) && values.include?(coverage[key]) },
          'Malformed report coverage; require every schema-1 range key and explicit bounded/partial/deferred values')
    required_unknowns = [{ 'kind' => 'snapshot_binding_unavailable' }]
    coverage.each do |feature, value|
      required_unknowns << { 'kind' => 'not_computed', 'feature' => feature } if value == 'not_computed'
    end
    check(required_unknowns.all? { |record| @data['unknowns'].include?(record) },
          'Report lacks required unbound snapshot or deferred-feature unknown evidence')
    check(@data['commits'].empty?, 'Report commits must be empty while their coverage is not_computed')
    check(@data['range'].is_a?(Hash), 'Malformed report range; require both retained endpoints')
    %w[from to].zip([@from, @to], [@before, @after]).each do |side, selector, reader|
      endpoint = @data['range'][side]
      check(endpoint.is_a?(Hash) && endpoint['generation'] == reader.generation_number, "Report #{side} generation differs from the requested retained range")
      check(endpoint['selector'] == selector, "Report #{side} selector differs; rerun woods:impact with the explicit gen:N selectors")
      check(endpoint['manifest_checksum'] == reader.external_dependency_checksum, "Report #{side} manifest checksum differs from the retained cache; regenerate the report")
      check(endpoint.key?('git_sha') && endpoint['git_sha'] == reader.manifest['git_sha'], "Report #{side} git_sha differs from the retained manifest")
    end
    validate_records
    identities = @data['changed'].map { |change| change.values_at('identifier', 'type') }
    check(identities.uniq.size == identities.size, 'Report contains duplicate changed typed identities')
    @change = @data['changed'].find { |change| change.values_at('identifier', 'type') == [@identifier, 'view_template'] }
    check(@change, 'Report lacks the expected template change; publish a controlled source change with app-relative CHANGED_FILES, then rerun woods:impact')
    check(@change['status'] == 'modified' && @change['facets'].is_a?(Array) && @change['facets'].include?('source') &&
          @change['categories'].is_a?(Array) && @change['categories'].include?('template') && @change['metadata_keys'].is_a?(Array),
          'Expected template must be modified in its source facet with template category; metadata-only/add/remove changes do not exercise this smoke')
    @sources = [@before, @after].map { |reader| reader.unit(@identifier, type: 'view_template').fetch('source_code') }
    check(@sources.first != @sources.last, 'Retained template source is identical; publish the controlled source change before running impact')
    stats = @sources.map { |source| { 'bytes' => source.bytesize, 'lines' => source.lines.size } }
    check(@change['diff_stats'] == { 'source_before' => stats.first, 'source_after' => stats.last }, 'Report diff_stats do not describe the retained template source')
    source_changes
  end

  def validate_records
    (@data['changed'] + @data['affected'] + @data['tables'] + @data['templates'] + @data['tests']).each do |record|
      check(%w[identifier type].all? { |key| record[key].is_a?(String) && !record[key].empty? }, 'Report record lacks a typed identity')
    end
    @data['changed'].each do |record|
      valid_arrays = %w[facets categories metadata_keys].all? do |key|
        record[key].is_a?(Array) && record[key].all? { |value| value.is_a?(String) && !value.empty? }
      end
      check(%w[added modified removed].include?(record['status']) && valid_arrays,
            'Malformed changed record status or facet/category/metadata arrays')
      check(!record['facets'].empty? && (record['facets'] - %w[source metadata dependencies]).empty? &&
            record['facets'].uniq == record['facets'], 'Malformed changed record facets')
      stats = record['diff_stats']
      valid_stats = stats.is_a?(Hash) && %w[source_before source_after].all? do |side|
        value = stats[side]
        valid_size = value.is_a?(Hash) && %w[bytes lines].all? { |key| value[key].is_a?(Integer) && value[key] >= 0 }
        stats.key?(side) && (value.nil? || valid_size)
      end
      check(valid_stats, 'Malformed changed record diff_stats')
    end
    roots = { 'from' => {}, 'to' => {} }
    @data['changed'].each do |change|
      side = change['status'] == 'removed' ? 'from' : 'to'
      roots[side][change.slice('identifier', 'type')] = true
    end
    (ARRAYS - ['changed']).each do |key|
      @data[key].each do |record|
        # Classify Report/Endpoint's actual exceptions before generic context
        # checks; losing both fields never turns an enrichment unknown global.
        next if key == 'unknowns' && validate_unscoped_unknown(record)

        side = record['endpoint']
        check(%w[from to].include?(side), "Report #{key} has invalid endpoint context")
        check(record['generation'].is_a?(Integer) && record['generation'] == @data['range'][side]['generation'],
              "Report #{key} lacks or mixes endpoint generation evidence")
        next unless key == 'affected'
        validate_witnesses(record, roots.fetch(side))
      end
    end
  end

  # Returns true only for the producer's global records or its one typed,
  # endpoint-only exception. Other kinds (including dynamic budget reasons)
  # go through the generic endpoint/generation check, without a guessed enum.
  def validate_unscoped_unknown(record)
    kind = record['kind']
    check(kind.is_a?(String) && !kind.empty?, 'Report unknowns need a nonempty kind')
    case kind
    when 'source_unavailable'
      check(record.keys.sort == %w[endpoint identifier kind type] &&
            %w[from to].include?(record['endpoint']) && typed_identity?(record.slice('identifier', 'type')),
            "source_unavailable unknown must carry the producer's exact endpoint-only typed shape")
    when 'not_computed'
      check(record.keys.sort == %w[feature kind] && COVERAGE[record['feature']] == ['not_computed'] &&
            @data['coverage'][record['feature']] == 'not_computed',
            'Malformed global not_computed unknown; require its deferred feature')
    when 'snapshot_binding_unavailable'
      check(record.keys == ['kind'], 'Malformed global snapshot_binding_unavailable unknown')
    when 'unclassified_source', 'unclassified_metadata'
      keys = %w[identifier kind type]
      keys << 'metadata_keys' if kind == 'unclassified_metadata'
      check(record.keys.sort == keys.sort && typed_identity?(record.slice('identifier', 'type')),
            'Malformed global unclassified unknown typed shape')
      if kind == 'unclassified_metadata'
        values = record['metadata_keys']
        check(values.is_a?(Array) && !values.empty? && values.all? { |value| value.is_a?(String) && !value.empty? },
              'Malformed global unclassified_metadata unknown metadata_keys')
      end
    else
      return false
    end
    true
  end

  def typed_identity?(value)
    value.is_a?(Hash) && value.keys.sort == %w[identifier type] &&
      value.values.all? { |part| part.is_a?(String) && !part.empty? }
  end

  def validate_witnesses(record, roots)
    paths = record['paths']
    check(paths.is_a?(Array) && !paths.empty?, 'Report affected witness paths must be a nonempty array')
    paths.each do |path|
      check(path.is_a?(Hash) && path['endpoint'] == record['endpoint'] && path['generation'] == record['generation'],
            'Report witness path mixes generations or has malformed context')
      root = path['root']
      check(typed_identity?(root) && roots.key?(root), 'Report witness root is untyped or belongs to another changed endpoint')
      edges = path['edges']
      check(edges.is_a?(Array) && !edges.empty?, 'Report witness edges must be a nonempty typed chain')
      cursor = root
      visited = [root]
      edges.each do |edge|
        check(edge.is_a?(Hash) && typed_identity?(edge['source']) && typed_identity?(edge['target']),
              'Report witness edge lacks exact typed source/target identities')
        check(edge['target'] == cursor && !visited.include?(edge['source']), 'Report witness chain is disconnected or cyclic')
        cursor = edge['source']
        visited << cursor
      end
      check(cursor == record.slice('identifier', 'type'), 'Report witness chain does not end at its affected typed identity')
    end
    check(record['distance'].is_a?(Integer) && record['distance'].positive? &&
          record['distance'] == paths.map { |path| path['edges'].size }.min, 'Report affected witness distance differs from its shortest chain')
  end

  def source_changes
    changes = @change['source_changes']
    check(changes.is_a?(Hash), 'Expected template lacks source_changes; use Woods with the published line-range contract')
    check(changes['coverage'] == 'complete', 'Expected template source_changes must be complete; use a smaller controlled template change')
    # One bounded pure comparison, not a Task, Report.compare or index write.
    expected = Woods::Impact::LineDiff.new(*@sources).ranges(max_hunks: 200)
    check(expected['coverage'] == 'complete', 'Retained template needs a complete bounded source diff; choose a smaller controlled change')
    check(changes.eql?(expected), 'Template source_changes hunks differ from the complete retained source ranges')
    @added_lines = []
    @removed_after = {}
    expected.fetch('hunks').each do |hunk|
      start, length = hunk.fetch('after')
      if length.positive?
        @added_lines.concat((start...(start + length)).to_a)
      elsif start.positive? && hunk.fetch('before').last.positive?
        @removed_after[start] = hunk.fetch('before').last
      end
    end
    check(@added_lines.any? || @removed_after.any?, 'Template change has no visible highlight anchor; add/replace a line or remove after a retained line')
  end

  def markdown
    expected = Woods::Impact::Renderers.markdown(@data)
    check(@captured_markdown == expected, 'Markdown differs from the real Woods renderer for the saved report; capture FORMAT=markdown stdout for this exact range')
    check(expected.lines.size <= 60 && expected.start_with?("## Change impact\n") &&
          expected.include?("Range: gen:#{@base} → gen:#{@head};") && expected.include?('**Incomplete report**') &&
          expected.include?("### Changed units (#{@data['changed'].size})") && expected.include?("### Unknowns (#{@data['unknowns'].size})") &&
          expected.include?('Coverage:'), 'Markdown is missing the bounded schema-1 range/change/coverage/unknowns contract')
  end

  def fetch(path)
    @session ||= Rack::MockRequest.new(Rails.application)
    headers = { 'REMOTE_ADDR' => '127.0.0.1', 'HTTP_HOST' => 'localhost', 'HTTP_ACCEPT' => 'text/html' }
    token = ENV['WOODS_MAP_TOKEN'].to_s
    headers['HTTP_AUTHORIZATION'] = "Bearer #{token}" unless token.empty?
    response = @session.get(path, headers)
    check(response.status == 200, "Map answered HTTP #{response.status}; verify /woods is mounted, WOODS_MAP_TOKEN and the retained range (redirects never count as success)")
    body = response.body.dup.force_encoding(Encoding::UTF_8)
    check(body.valid_encoding? && body.bytesize <= MAX_HTML_BYTES, 'Map HTML must be bounded and valid UTF-8')
    Nokogiri::HTML(body)
  end

  def text(node)
    node&.text.to_s.gsub(/\s+/, ' ').strip
  end

  def url_matches?(value, path, query, absolute: false)
    uri = URI.parse(value.to_s)
    pairs = URI.decode_www_form(uri.query.to_s, Encoding::UTF_8)
    return false unless pairs.size == query.size && pairs.to_h == query && uri.userinfo.nil? && uri.fragment.nil?
    if absolute
      base = URI.parse(WoodsMap.configuration.public_url || 'http://localhost')
      return false unless uri.is_a?(URI::HTTP) && [uri.scheme, uri.host, uri.port] == [base.scheme, base.host, base.port]
      path = URI::DEFAULT_PARSER.unescape(base.path).force_encoding(Encoding::UTF_8).delete_suffix('/') + path
    else
      return false unless uri.relative? && uri.host.nil?
    end
    URI::DEFAULT_PARSER.unescape(uri.path).force_encoding(Encoding::UTF_8) == path
  rescue URI::Error, ArgumentError
    false
  end

  def range_page
    query = { 'from' => @from, 'to' => @to, 'focus' => @identifier, 'lens' => 'changed' }
    doc = fetch("#{MOUNT}/impact?#{URI.encode_www_form(query)}")
    heading = doc.at_css('h1')&.dup
    heading&.css('.sub')&.each(&:remove) # shared/_ident nests its subtitle in h1
    check(text(heading) == "gen #{@base} → gen #{@head}", 'Map range is unavailable or addresses another range; verify retained payloads and Woods report support')
    check(text(doc).include?("map on gen #{@head}"), 'Map range rendered against another current generation')
    table = doc.at_css('table[aria-label="Changed units"]')
    @unit_path = "#{MOUNT}/units/view_template/#{@identifier}"
    row = table&.css('tbody tr')&.find do |candidate|
      candidate.css('td[data-h="unit"] a[href]').any? do |link|
        link.text == @identifier && url_matches?(link['href'], @unit_path, { 'since' => @from })
      end
    end
    check(row, 'Map range lacks the exact typed template link with since=base in Changed units')
    check(text(row.at_css('td[data-h="type"]')) == 'view template' && text(row.at_css('td[data-h="status"]')) == 'modified' &&
          text(row.at_css('td[data-h="facets moved"]')).split(/,\s*/).include?('source'), 'Map range row does not describe the modified template source')
    check(text(row.at_css('td[data-h="payload"]')) == "gen #{@head}", 'Map changed row has the wrong payload generation')
    check(row['class'].to_s.split.include?('focus') && row['aria-current'] == 'true' &&
          row.at_css('button[aria-expanded="true"]'), 'Map expected template row is not focused and expanded by its focus URL')
    @unit_href = row.css('td[data-h="unit"] a[href]').find { |link| url_matches?(link['href'], @unit_path, { 'since' => @from }) }['href']
    button = doc.css('button[data-copy-text-value]').find { |candidate| text(candidate).include?('copy focus URL') }
    check(button && url_matches?(button['data-copy-text-value'], "#{MOUNT}/impact", query, absolute: true),
          'Map copy focus URL must preserve from/to/focus/lens at the configured public URL, without credentials or token')
  end

  def since_page
    doc = fetch(@unit_href)
    banner = doc.at_css('.frame-facts .banner.mod')
    check(text(banner).include?("Modified since gen #{@base}.") && text(banner).include?("Woods' report, gen #{@base} → gen #{@head}"),
          'Template since range is unavailable or mixes the head generation; freeze publishing and retain both endpoints')
    report_link_present = banner.css('a[href]').any? do |link|
      url_matches?(link['href'], "#{MOUNT}/impact", { 'from' => @from, 'to' => 'now', 'focus' => @identifier, 'lens' => 'changed' })
    end
    check(report_link_present, 'Template since range lost its matching report link')
    wrapper = doc.css('.cvwrap').find { |node| node['aria-label'] == "Source of #{@identifier}, as written lens" }
    check(wrapper, 'Map source view does not name the expected template')
    added = []
    removed = []
    wrapper.css('.cv .row').each do |row|
      # row-chg also styles metadata-only notes. Accessible gutter labels are
      # the source-change contract, so inspect those before comparing both ways.
      labels = row.css('.ln .sr-only').map { |label| text(label) }
      changed = labels.select { |label| label.include?('changed since gen') }
      deletions = labels.select { |label| label.include?('removed after it since gen') }
      next if changed.empty? && deletions.empty?

      check(row['id'].to_s.match?(/\AL[1-9]\d*\z/), 'Map source highlight lacks a visible line anchor')
      line = row['id'].delete_prefix('L').to_i
      classes = row['class'].to_s.split
      unless changed.empty?
        check(changed == [", changed since gen #{@base}"] && classes.include?('row-chg'), 'Map source highlight has malformed or mixed-generation changed labels')
        added << line
      end
      deletions.each do |label|
        match = /\A, ([1-9]\d*) (line|lines) removed after it since gen (\d+)\z/.match(label)
        check(match && match[3] == @base.to_s && classes.include?('row-rm') &&
              match[2] == (match[1] == '1' ? 'line' : 'lines'), 'Map deletion highlight has malformed or mixed-generation removal labels')
        removed << [line, match[1].to_i]
      end
    end
    check(added.sort == @added_lines.sort && removed.sort == @removed_after.to_a.sort,
          'Map source highlight labels differ from the complete retained template changes (missing or extra marks)')
  end

  def stable_head
    WoodsMap::Repository.open(@index) do |repository|
      check(File.realpath(repository.index_dir.to_s) == @index && repository.generation_number == @head && repository.manifest == @after.manifest,
            'Current Map index/head changed during the smoke; freeze publication and rerun the retained range')
    end
    check([@base, @head].all? { |number| Woods::PublishedIndex.available_generations(@index).include?(number) },
          'A range endpoint is no longer retained; restore the base cache and rerun before other publishers')
  end
end

exit WoodsMapImpactSmoke.new.run
