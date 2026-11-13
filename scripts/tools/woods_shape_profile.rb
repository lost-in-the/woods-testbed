# frozen_string_literal: true

# Woods shape profile: the SHAPE of a Rails application and its Woods index,
# as numbers, with nothing that identifies the application.
#
# Run it once in any Rails app that has Woods installed and an extraction on
# disk (bin/rails woods:extract):
#
#   bin/rails runner path/to/woods_shape_profile.rb [index_dir] [--out FILE] [--timings]
#
# index_dir defaults to tmp/woods. It prints one JSON document
# ("profile_version": 1). Compare two profiles with plain Ruby, no Rails:
#
#   ruby path/to/woods_shape_profile.rb --compare a.json b.json
#
# It also runs without Rails against an index alone (the self-test does this):
#
#   ruby path/to/woods_shape_profile.rb --root APP_ROOT [index_dir]
#
# WHAT IT EMITS
#   Counts, ratios and distributions (count, min, p50, p90, p99, max, mean and
#   a log2 histogram) of: units by type, source and metadata size, graph
#   degrees, hub in-degrees, blast radius, namespace spread, cycles, model and
#   controller facts, file sizes, gem count, git history volume, and the run
#   facts Woods records in its manifest.
#
# THE PRIVACY GUARANTEE
#   The only strings in the output come from fixed lists in this file:
#     * the schema's own key names and enum values (ALLOWED_KEYS, ENUMS);
#     * Woods unit type names and type directory names (UNIT_TYPES, TYPE_DIRS);
#     * Woods edge `via` labels (VIA_LABELS). A unit type or a `via` label that
#       is not in the list is counted under "other", never printed;
#     * Ruby, Rails and Woods version numbers, accepted only when they match
#       VERSION_PATTERN (digits, dots and a prerelease word).
#   No identifier, class, module, file path, table, column, route, gem, author,
#   commit message, branch, SHA, hostname, username or directory is ever copied
#   into the document: app strings are only measured (length, count, equality).
#   This holds by construction, and Privacy.verify! re-checks the finished
#   document before anything is printed: it walks every key and every string
#   value and aborts, printing nothing, when one is outside the lists.
#
# ITS LIMITS
#   * Numbers describe the app. Exact totals (4,217 models, 913 gems) can
#     confirm a guess by someone who already has the code. They cannot name it.
#   * Version numbers are emitted (Ruby, Rails, Woods).
#   * A very small app has few enough units that its distributions are close
#     to a fingerprint of it.
#   * The self-check proves that no string outside the lists is emitted. It
#     does not judge whether a number is sensitive to you: read the JSON before
#     you send it. It is short.
#
# WHAT IT TOUCHES
#   No network. It reads the index, stats the files under the application root
#   (line counts only), reads Gemfile.lock, and runs read-only `git` commands.
#   It writes nothing except the file named by --out. `--timings` boots the
#   application twice in child processes (`bin/rails runner`), which does
#   whatever booting your app does (logs, bootsnap cache).

require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'set'

module WoodsShapeProfile
  PROFILE_VERSION = 1

  # Woods' unit type directories (Woods::MCP::IndexReader::TYPE_DIRS, 2.1.0 through main).
  TYPE_DIRS = %w[
    models controllers graphql components view_components services jobs mailers serializers managers policies
    validators concerns routes middleware i18n pundit_policies configurations engines view_templates migrations
    action_cable_channels scheduled_jobs rake_tasks state_machines events decorators database_views database_tables
    external_consumers caching factories test_mappings test_support rails_source poros libs packages
    graphql_operations config_files js_modules docs ruby_classes ruby_modules ruby_methods ruby_files
  ].freeze

  # Woods' unit types: the singular of each directory plus the subtypes some directories hold.
  UNIT_TYPES = %w[
    model controller graphql component view_component service job mailer serializer manager policy validator
    concern route middleware i18n pundit_policy configuration engine view_template migration action_cable_channel
    scheduled_job rake_task state_machine event decorator database_view database_table external_consumer caching
    factory test_mapping test_support rails_source poro lib package graphql_operation config_file js_module doc
    ruby_class ruby_module ruby_method ruby_file gem_source route_file graphql_type graphql_mutation
    graphql_resolver graphql_query
  ].freeze

  # Woods' edge labels. Anything else is counted as "other".
  VIA_LABELS = %w[
    action_source alpine_data authorization behaves_like behavioral_profile belongs_to code_reference configuration
    data_dependency decoration definition_of delegation dependency dependent doc_link documents draw drawn_in
    engine_route exercises_route extend external_call factory_association factory_for factory_parent field_resolver
    foreign_key form_action fragment_spread has_and_belongs_to_many has_many has_one helper_call helper_method
    import include includes_helper inheritance job_enqueue link_to method_call migrates mount owner_expansion
    package_dependency policy_evaluation polymorphic_interface prepend published_by reads_config reads_table
    redirect_to reference render require root_field route_dispatch scheduled serialization service_call slot
    state_machine state_machine_callback subscribed_by table table_name task_dependency task_invoke test_coverage
    through_chain type_reference validation view_render view_source writes_table
  ].freeze

  OTHER = 'other'
  UNLABELLED = 'unlabelled'

  # Every other string value the document may carry.
  ENUMS = (%w[
    published_index direct full incremental refresh seed watch unknown available unavailable partial
    shallow git_unavailable not_a_repository no_app_root not_requested no_rails no_lockfile child_failed
    missing unreadable
  ] + [OTHER, UNLABELLED]).freeze

  VERSION_KEYS = %w[ruby_version rails_version woods_version].freeze
  VERSION_PATTERN = /\A\d{1,4}(\.\d{1,4}){1,4}(\.?(alpha|beta|rc|pre|dev)\.?\d{0,3})?\z/

  ALLOWED_KEYS = (%w[
    profile_version available index graph models controllers files app_weight history woods_run
    reader total_units units_by_type source_lines source_bytes metadata_bytes chunks_per_unit unit_file_bytes
    overall by_type count min p50 p90 p99 max mean sum histogram le
    nodes edges edges_per_node resolved_edges unresolved_edge_share variant_records edges_by_via
    out_degree in_degree all top_hubs rank type top_hub_blast_radius direct_share depth_2_share depth_3_share
    transitive_share transitive_units depth truncated top_5_transitive_shares top_20_max_transitive_share
    structural_share structural_units
    model_blast_radius sampled_models
    units node_limit namespaces top_level_namespaces root_units namespaced_units units_per_namespace
    cross_namespace_edge_share cross_namespace_edge_share_including_root namespaced_edge_share
    cycles strongly_connected_components largest_component units_in_components self_loops analysis
    orphan_count dead_end_count hub_count cycle_count cycle_limit_reached cross_database_edge_count
    volatile_dependency_count undeclared_package_edge_count unresolvable_route_count unmodelled_table_count
    domain_cluster_count
    associations callbacks application_callbacks validations scopes inlined_concerns columns enums methods
    sti_children concern_fan_in_top_10 concern_fan_in_top_10_all_units concerns_included_by_models
    tables indexes foreign_keys
    actions filters application_filters routes routes_per_controller routes_total_index routes_total_runtime
    ruby app lib packages elsewhere lines view_templates test_files walk_truncated files_seen
    gems_in_lockfile gems_loaded ruby_version rails_version eager_load_configured engines initializers timings
    boot_seconds eager_load_seconds eager_boot_wall_seconds autoloaded_constants modules_defined_by_eager_load
    active_record_descendants
    reason total_commits commits_last_365_days contributors files_per_commit commits_per_app_file
    commits_walked app_files_touched
    woods_version extraction_mode generation total_chunks units_by_directory extractor_timings
    extractor_timings_total git_enrichment_state
  ] + UNIT_TYPES + TYPE_DIRS + VIA_LABELS + [OTHER, UNLABELLED]).to_set.freeze

  ALLOWED_STRINGS = (UNIT_TYPES + TYPE_DIRS + VIA_LABELS + ENUMS).to_set.freeze

  # The gate between the collected document and stdout.
  module Privacy
    class Leak < StandardError; end

    module_function

    # @param document [Hash] the profile exactly as it will be serialized (string keys)
    # @raise [Leak] naming the JSON path (never the offending value) of the first violation
    def verify!(document, path = '$')
      case document
      when Hash
        document.each do |key, value|
          raise Leak, "key outside the allow-list under #{path}" unless ALLOWED_KEYS.include?(key)

          if value.is_a?(String) && VERSION_KEYS.include?(key)
            raise Leak, "malformed version at #{path}.#{key}" unless VERSION_PATTERN.match?(value)
          else
            verify!(value, "#{path}.#{key}")
          end
        end
      when Array then document.each_with_index { |value, index| verify!(value, "#{path}[#{index}]") }
      when String then raise Leak, "string outside the allow-list at #{path}" unless ALLOWED_STRINGS.include?(document)
      when Integer, true, false, nil then nil
      when Float then raise Leak, "non-finite number at #{path}" unless document.finite?
      else raise Leak, "unexpected #{document.class} at #{path}"
      end
      document
    end

    # Serialize, re-read and verify: what is checked is what is printed.
    #
    # @return [String] pretty JSON; aborts the process instead when the check fails
    def seal(profile)
      document = JSON.parse(JSON.generate(profile))
      verify!(document)
      JSON.pretty_generate(document)
    rescue Leak => e
      abort "woods_shape_profile: privacy self-check failed (#{e.message}); nothing was written."
    end

    def unit_type(value)
      UNIT_TYPES.include?(value) ? value : OTHER
    end

    def via(value)
      return UNLABELLED if value.nil?

      VIA_LABELS.include?(value.to_s) ? value.to_s : OTHER
    end

    def enum(value, known, fallback = OTHER)
      known.include?(value) ? value : fallback
    end

    def version(value)
      value.is_a?(String) && VERSION_PATTERN.match?(value) ? value : nil
    end
  end

  # Summary statistics. Nothing here ever sees more than numbers.
  module Stats
    module_function

    def dist(values, histogram: false)
      sorted = values.compact.sort
      return { count: 0 } if sorted.empty?

      result = { count: sorted.size, min: num(sorted.first), p50: num(pct(sorted, 50)), p90: num(pct(sorted, 90)),
                 p99: num(pct(sorted, 99)), max: num(sorted.last), mean: (sorted.sum.to_f / sorted.size).round(2) }
      result[:histogram] = histogram(sorted) if histogram
      result
    end

    def pct(sorted, percent)
      sorted[[(percent / 100.0 * sorted.size).ceil - 1, 0].max]
    end

    # Log2 buckets by inclusive upper bound: 0, 1, 2, 4, 8, ...
    def histogram(sorted)
      sorted.each_with_object(Hash.new(0)) { |value, buckets| buckets[bound(value.ceil)] += 1 }
            .sort.map { |le, count| { le: le, count: count } }
    end

    def bound(value)
      value <= 1 ? [value, 0].max : 1 << (value - 1).bit_length
    end

    def num(value)
      value.is_a?(Float) ? value.round(3) : value
    end

    def ratio(part, whole)
      whole.to_f.zero? ? nil : (part.to_f / whole).round(4)
    end

    def by_type(table)
      table.sort.to_h { |type, values| [type, dist(values)] }
    end
  end

  # Reads one published generation, through Woods' own reader when it is loaded.
  class IndexSource
    attr_reader :payload_dir, :reader_name

    def initialize(index_dir)
      @index_dir = File.expand_path(index_dir)
      @published = open_published
      @reader_name = @published ? 'published_index' : 'direct'
      @payload_dir = @published ? @published.payload_dir.to_s : direct_payload_dir
      abort "woods_shape_profile: no Woods index (manifest.json) under #{index_dir}" unless artifact?('manifest.json')
    end

    def close
      @published&.close
    end

    def each_unit(&block)
      if @published.respond_to?(:each_unit)
        begin
          return @published.each_unit(&block)
        rescue StandardError
          @reader_name = 'direct'
        end
      end
      each_unit_directly(&block)
    end

    # @return [Hash, Array, nil] a Woods JSON artifact of the payload, read as UTF-8
    def artifact(name)
      path = File.join(@payload_dir, name)
      return nil unless File.file?(path)

      JSON.parse(read(path))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def artifact?(name)
      File.file?(File.join(@payload_dir, name))
    end

    def marker
      path = File.join(@index_dir, 'generation.json')
      data = File.file?(path) ? JSON.parse(read(path)) : {}
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def unit_file_sizes
      Dir.glob(File.join(@payload_dir, '*', '*.json')).reject { |path| File.basename(path).start_with?('_') }
         .map { |path| File.size(path) }
    end

    private

    def open_published
      require 'woods/published_index' unless defined?(Woods::PublishedIndex)
      Woods::PublishedIndex.new(@index_dir)
    rescue LoadError, StandardError
      nil
    end

    def direct_payload_dir
      payload = marker['payload']
      candidate = payload.is_a?(String) ? File.expand_path(payload, @index_dir) : @index_dir
      candidate.start_with?(@index_dir) && File.directory?(candidate) ? candidate : @index_dir
    end

    def each_unit_directly
      Dir.children(@payload_dir).sort.each do |dir|
        Dir.glob(File.join(@payload_dir, dir, '*.json')).sort.each do |path|
          next if File.basename(path).start_with?('_')

          unit = begin
            JSON.parse(read(path))
          rescue JSON::ParserError, SystemCallError
            nil
          end
          yield unit if unit.is_a?(Hash) && unit['identifier']
        end
      end
    end

    def read(path)
      File.read(path, encoding: 'UTF-8')
    end
  end

  # Units by type, source and metadata size, and the model and controller facts.
  class UnitFacts
    def initialize
      @types = Hash.new(0)
      @lines = Hash.new { |hash, key| hash[key] = [] }
      @bytes = Hash.new { |hash, key| hash[key] = [] }
      @metadata = Hash.new { |hash, key| hash[key] = [] }
      @chunks = []
      @model = Hash.new { |hash, key| hash[key] = [] }
      @controller = Hash.new { |hash, key| hash[key] = [] }
      @table = Hash.new { |hash, key| hash[key] = [] }
      @concern_models = Hash.new(0)
      @sti_children = 0
    end

    def add(unit)
      type = Privacy.unit_type(unit['type'])
      metadata = unit['metadata'].is_a?(Hash) ? unit['metadata'] : {}
      source = unit['source_code'].is_a?(String) ? unit['source_code'] : ''
      @types[type] += 1
      @lines[type] << line_count(source)
      @bytes[type] << source.bytesize
      @metadata[type] << JSON.generate(metadata).bytesize
      @chunks << Array(unit['chunks']).size
      case type
      when 'model' then add_model(metadata)
      when 'controller' then add_controller(metadata)
      when 'database_table' then add_table(metadata)
      end
    end

    def index(source)
      { reader: source.reader_name, total_units: @types.values.sum, units_by_type: @types.sort.to_h,
        source_lines: sized(@lines), source_bytes: sized(@bytes), metadata_bytes: sized(@metadata),
        chunks_per_unit: Stats.dist(@chunks, histogram: true),
        unit_file_bytes: Stats.dist(source.unit_file_sizes, histogram: true) }
    end

    def models
      fan_in = @concern_models.values.sort.reverse
      result = @model.sort.to_h { |key, values| [key, Stats.dist(values, histogram: true)] }
      result.merge(count: @types['model'], sti_children: @sti_children, concerns_included_by_models: fan_in.size,
                   concern_fan_in_top_10: fan_in.first(10),
                   tables: @table.sort.to_h { |key, values| [key, Stats.dist(values)] })
    end

    def controllers(runtime_routes)
      per = @controller.sort.to_h { |key, values| [key, Stats.dist(values, histogram: true)] }
      per.merge(count: @types['controller'], routes_total_index: @types['route'],
                routes_total_runtime: runtime_routes)
    end

    private

    def sized(table)
      { overall: Stats.dist(table.values.flatten, histogram: true), by_type: Stats.by_type(table) }
    end

    def line_count(source)
      return 0 if source.empty?

      source.count("\n") + (source.end_with?("\n") ? 0 : 1)
    end

    def size_of(metadata, list_key, count_key = nil)
      value = metadata[list_key]
      return value.size if value.is_a?(Array) || value.is_a?(Hash)

      count = count_key && metadata[count_key]
      count.is_a?(Integer) ? count : nil
    end

    def application_origin(list)
      return nil unless list.is_a?(Array)

      list.count { |entry| !entry.is_a?(Hash) || entry['origin'] != 'framework' }
    end

    def add_model(metadata)
      @model[:associations] << size_of(metadata, 'associations', 'association_count')
      @model[:callbacks] << size_of(metadata, 'callbacks', 'callback_count')
      @model[:application_callbacks] << application_origin(metadata['callbacks'])
      @model[:validations] << size_of(metadata, 'validations', 'validation_count')
      @model[:scopes] << size_of(metadata, 'scopes')
      @model[:inlined_concerns] << size_of(metadata, 'inlined_concerns')
      @model[:columns] << size_of(metadata, 'columns', 'column_count')
      @model[:enums] << size_of(metadata, 'enums')
      @model[:methods] << size_of(metadata, 'methods')
      @sti_children += 1 if metadata['is_sti_child'] == true
      Array(metadata['inlined_concerns']).uniq.each { |name| @concern_models[name] += 1 }
    end

    def add_controller(metadata)
      @controller[:actions] << size_of(metadata, 'actions', 'action_count')
      @controller[:filters] << size_of(metadata, 'filters', 'filter_count')
      @controller[:application_filters] << application_origin(metadata['filters'])
      routes = metadata['routes']
      @controller[:routes_per_controller] << (routes.is_a?(Hash) ? routes.values.sum { |list| Array(list).size } : nil)
    end

    def add_table(metadata)
      @table[:columns] << size_of(metadata, 'columns', 'column_count')
      @table[:indexes] << size_of(metadata, 'indexes')
      @table[:foreign_keys] << size_of(metadata, 'foreign_keys')
    end
  end

  # Degrees, hubs, blast radius, namespaces and cycles from dependency_graph.json.
  class GraphFacts
    DEGREE_TYPES = %w[model controller service job].freeze
    NODE_LIMIT = 250_000
    # Woods::Extractor::STRUCTURAL_VIAS: the edges `incremental_blast_radius_depth = :structural` follows.
    STRUCTURAL_VIAS = %w[inheritance include extend].freeze
    MODEL_SAMPLE = 200
    ANALYSIS_KEYS = %w[orphan_count dead_end_count hub_count cycle_count cycle_limit_reached
                       cross_database_edge_count volatile_dependency_count undeclared_package_edge_count
                       unresolvable_route_count unmodelled_table_count domain_cluster_count].freeze

    def initialize(graph, analysis)
      @graph = graph.is_a?(Hash) ? graph : {}
      @analysis = analysis.is_a?(Hash) ? analysis : {}
      @nodes = @graph['nodes'].is_a?(Hash) ? @graph['nodes'] : {}
      build
    end

    def to_h
      return { available: false, reason: 'missing' } if @nodes.empty?

      { available: true, nodes: @ids.size, edges: @edge_count, edges_per_node: Stats.ratio(@edge_count, @ids.size),
        resolved_edges: @resolved, unresolved_edge_share: Stats.ratio(@edge_count - @resolved, @edge_count),
        variant_records: Array(@graph['variants']).size, edges_by_via: @vias.sort_by { |via, n| [-n, via] }.to_h,
        out_degree: degrees(@out.map(&:size)), in_degree: degrees(@in.map(&:size)), top_hubs: top_hubs,
        top_hub_blast_radius: top_hub_blast_radius, model_blast_radius: model_blast_radius,
        namespaces: namespaces, cycles: cycles }
    end

    private

    # Identifiers become integers here and are never read again.
    def build
      @ids = @nodes.keys.each_with_index.to_h
      @types = @nodes.values.map { |node| Privacy.unit_type(node.is_a?(Hash) ? node['type'] : nil) }
      @out = Array.new(@ids.size) { Set.new }
      @in = Array.new(@ids.size) { Set.new }
      @in_structural = Array.new(@ids.size) { Set.new }
      @vias = Hash.new(0)
      @edge_count = @resolved = @self_loops = 0
      @namespace = namespace_ids
      @cross = @cross_with_root = @both_namespaced = 0
      each_raw_edge { |from, target, via| add_edge(from, target, via) }
    end

    def each_raw_edge
      lists = (@graph['edges'].is_a?(Hash) ? @graph['edges'] : {}).to_a
      lists += Array(@graph['variants']).filter_map { |v| [v['identifier'], v['edges']] if v.is_a?(Hash) }
      lists.each do |from, list|
        Array(list).each do |raw|
          raw.is_a?(Hash) ? yield(from, raw['target'], raw['via']) : yield(from, raw.to_s, nil)
        end
      end
    end

    def add_edge(from, target, via)
      @edge_count += 1
      @vias[Privacy.via(via)] += 1
      a = @ids[from]
      b = @ids[target]
      return unless a && b

      @resolved += 1
      @self_loops += 1 if a == b
      @out[a] << b
      @in[b] << a
      @in_structural[b] << a if STRUCTURAL_VIAS.include?(via.to_s)
      count_namespaces(@namespace[a], @namespace[b])
    end

    def count_namespaces(left, right)
      @cross_with_root += 1 if left != right
      return unless left && right

      @both_namespaced += 1
      @cross += 1 if left != right
    end

    # Top-level namespace of each node as a small integer; nil for the root.
    def namespace_ids
      seen = {}
      @nodes.map do |identifier, node|
        name = node.is_a?(Hash) && node['namespace'].is_a?(String) ? node['namespace'] : nil
        top = name ? name.split(%r{::|/}).first : identifier[/\A([A-Z][A-Za-z0-9_]*)::/, 1]
        # `Billing` (a class) and `billing` (a view directory) are one namespace.
        top = top.to_s.downcase.delete('_')
        top.empty? ? nil : (seen[top] ||= seen.size)
      end
    end

    def degrees(values)
      result = { all: Stats.dist(values, histogram: true) }
      DEGREE_TYPES.each do |type|
        result[type] = Stats.dist(values.each_with_index.filter_map { |value, i| value if @types[i] == type })
      end
      result
    end

    def hubs
      @hubs ||= (0...@ids.size).sort_by { |i| [-@in[i].size, i] }.first(20).reject { |i| @in[i].empty? }
    end

    def top_hubs
      hubs.each_with_index.map do |i, rank|
        { rank: rank + 1, in_degree: @in[i].size, out_degree: @out[i].size, type: @types[i] }
      end
    end

    # Units that reach `start` through reverse edges, breadth first, by depth.
    # This is Woods' unbounded blast radius (DependencyGraph#affected_by), which
    # never re-extracts a document for the code it mentions.
    def dependents_by_depth(start, limit)
      seen = { start => 0 }
      queue = [start]
      until queue.empty? || seen.size > limit
        node = queue.shift
        @in[node].each do |source|
          next if seen.key?(source) || @types[source] == 'doc'

          seen[source] = seen[node] + 1
          queue << source
        end
      end
      seen.delete(start)
      [seen, !queue.empty?]
    end

    # Woods' `:structural` blast radius: the closure over structural edges, then
    # one hop along any edge from every unit that closure reached.
    def structural_dependents(start)
      reached = Set[start]
      queue = [start]
      while (node = queue.shift)
        @in_structural[node].each { |source| queue << source if @types[source] != 'doc' && reached.add?(source) }
      end
      result = reached.dup
      reached.each { |node| @in[node].each { |source| result << source unless @types[source] == 'doc' } }
      result.size - 1
    end

    def top_hub_blast_radius
      return { available: false, reason: 'missing' } if hubs.empty?

      seen, truncated = dependents_by_depth(hubs.first, NODE_LIMIT)
      depths = seen.values
      share = ->(max) { Stats.ratio(depths.count { |depth| depth <= max }, @ids.size) }
      { available: true, direct_share: share.call(1), depth_2_share: share.call(2), depth_3_share: share.call(3),
        transitive_share: Stats.ratio(depths.size, @ids.size), transitive_units: depths.size,
        depth: depths.max || 0, truncated: truncated, node_limit: NODE_LIMIT,
        structural_share: Stats.ratio(structural_dependents(hubs.first), @ids.size),
        top_5_transitive_shares: hub_shares.first(5), top_20_max_transitive_share: hub_shares.max }
    end

    def hub_shares
      @hub_shares ||= hubs.map { |hub| Stats.ratio(dependents_by_depth(hub, NODE_LIMIT).first.size, @ids.size) }
    end

    # Transitive dependents of an evenly spaced sample of models.
    def model_blast_radius
      models = (0...@ids.size).select { |i| @types[i] == 'model' }
      step = [(models.size / MODEL_SAMPLE.to_f).ceil, 1].max
      sample = models.each_slice(step).map(&:first)
      sizes = sample.map { |model| dependents_by_depth(model, NODE_LIMIT).first.size }
      structural = sample.map { |model| structural_dependents(model) }
      { sampled_models: sample.size, units: Stats.dist(sizes, histogram: true),
        structural_units: Stats.dist(structural, histogram: true) }
    end

    def namespaces
      sizes = @namespace.compact.tally.values
      { top_level_namespaces: sizes.size, root_units: @namespace.count(&:nil?), namespaced_units: sizes.sum,
        units_per_namespace: Stats.dist(sizes, histogram: true),
        namespaced_edge_share: Stats.ratio(@both_namespaced, @resolved),
        cross_namespace_edge_share: Stats.ratio(@cross, @both_namespaced),
        cross_namespace_edge_share_including_root: Stats.ratio(@cross_with_root, @resolved) }
    end

    def cycles
      components = strongly_connected_components.select { |size| size > 1 }
      stats = @analysis['stats'].is_a?(Hash) ? @analysis['stats'] : {}
      analysis = ANALYSIS_KEYS.to_h { |key| [key, stats[key]] }
                              .select { |_, value| value.is_a?(Integer) || [true, false].include?(value) }
      { strongly_connected_components: components.size, largest_component: components.max || 0,
        units_in_components: components.sum, self_loops: @self_loops, analysis: analysis }
    end

    # Iterative Tarjan; returns the size of every component.
    def strongly_connected_components
      index = Array.new(@ids.size)
      low = Array.new(@ids.size)
      on_stack = Array.new(@ids.size, false)
      stack = []
      sizes = []
      counter = 0
      adjacency = @out.map(&:to_a)
      @ids.size.times do |root|
        next if index[root]

        work = [[root, 0]]
        until work.empty?
          node, position = work.last
          if position.zero?
            index[node] = low[node] = counter
            counter += 1
            stack << node
            on_stack[node] = true
          end
          if position < adjacency[node].size
            work.last[1] += 1
            target = adjacency[node][position]
            if index[target].nil?
              work << [target, 0]
            elsif on_stack[target]
              low[node] = [low[node], index[target]].min
            end
          else
            work.pop
            low[work.last[0]] = [low[work.last[0]], low[node]].min unless work.empty?
            next unless low[node] == index[node]

            size = 0
            loop do
              member = stack.pop
              on_stack[member] = false
              size += 1
              break if member == node
            end
            sizes << size
          end
        end
      end
      sizes
    end
  end

  # Concern fan-in over every unit type, from the graph's `include` edges.
  module ConcernFanIn
    module_function

    def top_10(graph)
      nodes = graph.is_a?(Hash) && graph['nodes'].is_a?(Hash) ? graph['nodes'] : {}
      counts = Hash.new { |hash, key| hash[key] = Set.new }
      (graph.is_a?(Hash) && graph['edges'].is_a?(Hash) ? graph['edges'] : {}).each do |from, list|
        Array(list).each do |raw|
          next unless raw.is_a?(Hash) && raw['via'] == 'include'

          target = nodes[raw['target']]
          counts[raw['target']] << from if target.is_a?(Hash) && target['type'] == 'concern'
        end
      end
      counts.values.map(&:size).sort.reverse.first(10)
    end
  end

  # File counts and line counts under the application root. No path leaves this class.
  class FileFacts
    SKIP = %w[.git node_modules vendor tmp log storage public coverage .bundle].freeze
    PACKAGE_ROOTS = %w[packs packages engines components gems].freeze
    TEST_DIRS = %w[spec test features].freeze
    LIMIT = 500_000

    def initialize(root)
      @root = root
      @lines = Hash.new { |hash, key| hash[key] = [] }
      @views = @tests = @seen = 0
      @truncated = false
    end

    def to_h
      return { available: false, reason: 'no_app_root' } unless @root && File.directory?(@root)

      walk(@root, [])
      { available: true,
        ruby: %i[app lib packages elsewhere].to_h do |bucket|
          [bucket, { count: @lines[bucket].size, lines: Stats.dist(@lines[bucket], histogram: true) }]
        end.merge(all: { count: all_lines.size, lines: Stats.dist(all_lines, histogram: true) }),
        view_templates: @views, test_files: @tests, files_seen: @seen, walk_truncated: @truncated }
    end

    private

    def all_lines
      @lines.values.flatten
    end

    def walk(dir, segments)
      entries = begin
        Dir.children(dir).sort
      rescue SystemCallError
        []
      end
      entries.each do |name|
        return @truncated = true if @seen >= LIMIT

        path = File.join(dir, name)
        next if File.symlink?(path)

        if File.directory?(path)
          walk(path, segments + [name]) unless segments.empty? && SKIP.include?(name)
        elsif File.file?(path)
          @seen += 1
          classify(path, name, segments)
        end
      end
    end

    def classify(path, name, segments)
      if segments.intersect?(TEST_DIRS)
        @tests += 1 if name.end_with?('_spec.rb', '_test.rb', '.feature')
      elsif segments.each_cons(2).include?(%w[app views])
        @views += 1
      elsif name.end_with?('.rb', '.rake')
        @lines[bucket(segments)] << count_lines(path)
      end
    end

    def bucket(segments)
      return :app if segments.first == 'app'
      return :lib if segments.first == 'lib'

      PACKAGE_ROOTS.include?(segments.first) ? :packages : :elsewhere
    end

    def count_lines(path)
      count = 0
      File.open(path, 'rb') { |io| count += io.read(1 << 16).count("\n") until io.eof? }
      count
    rescue SystemCallError
      0
    end
  end

  # Gem count, versions, and (opt-in) boot and eager-load timings in child processes.
  class AppWeight
    MARKER = 'WOODS_SHAPE_TIMING'
    CHILD = <<~RUBY
      before = ObjectSpace.each_object(Module).count
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Rails.application.eager_load!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expected = begin
        Rails.autoloaders.main.all_expected_cpaths.values.flatten.uniq.size
      rescue StandardError, NotImplementedError
        -1
      end
      models = defined?(ActiveRecord::Base) ? ActiveRecord::Base.descendants.size : -1
      puts ['#{MARKER}', elapsed.round(3), ObjectSpace.each_object(Module).count - before, expected, models].join(' ')
    RUBY

    def initialize(root, manifest, timings:)
      @root = root
      @manifest = manifest
      @timings = timings
    end

    def to_h
      rails = defined?(Rails) && Rails.respond_to?(:application)
      { gems_in_lockfile: lockfile_gems, gems_loaded: rails ? Gem.loaded_specs.size : nil,
        ruby_version: Privacy.version(rails ? RUBY_VERSION : @manifest['ruby_version']),
        rails_version: Privacy.version(rails ? Rails.version : @manifest['rails_version']),
        eager_load_configured: rails ? guarded { Rails.application.config.eager_load == true } : nil,
        engines: rails ? guarded { Rails::Engine.subclasses.size } : nil,
        initializers: rails ? guarded { Rails.application.initializers.count } : nil,
        timings: timings(rails) }
    end

    private

    def guarded
      yield
    rescue StandardError
      nil
    end

    def lockfile_gems
      path = defined?(Bundler) && guarded { Bundler.default_lockfile.to_s }
      path = File.join(@root, 'Gemfile.lock') if @root && !(path && File.file?(path))
      return nil unless path && File.file?(path)

      File.read(path, encoding: 'UTF-8').each_line.count { |line| line.match?(/\A {4}\S+ \(/) }
    rescue SystemCallError
      nil
    end

    def timings(rails)
      return { available: false, reason: 'not_requested' } unless @timings
      return { available: false, reason: 'no_rails' } unless rails && @root && File.file?(File.join(@root, 'bin/rails'))

      boot, = run_child('nil')
      wall, output = run_child(CHILD)
      fields = output.to_s[/^#{MARKER} ([\d. -]+)$/, 1]&.split
      return { available: false, reason: 'child_failed' } unless boot && wall && fields&.size == 4

      positive = ->(text) { text.to_i.negative? ? nil : text.to_i }
      { available: true, boot_seconds: boot.round(2), eager_load_seconds: fields[0].to_f,
        eager_boot_wall_seconds: wall.round(2), modules_defined_by_eager_load: fields[1].to_i,
        autoloaded_constants: positive.call(fields[2]), active_record_descendants: positive.call(fields[3]) }
    end

    def run_child(code)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output, status = Open3.capture2e(RbConfig.ruby, 'bin/rails', 'runner', code, chdir: @root)
      status.success? ? [Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, output] : nil
    rescue SystemCallError
      nil
    end
  end

  # Volume of history, from read-only git commands. Names and messages are never requested.
  class HistoryFacts
    COMMIT_LIMIT = 200_000
    SEPARATOR = "\x01"

    def initialize(root)
      @root = root
    end

    def to_h
      return unavailable('no_app_root') unless @root && File.directory?(@root)
      return unavailable('git_unavailable') unless git_present?
      return unavailable('not_a_repository') unless git('rev-parse', '--is-inside-work-tree')&.strip == 'true'
      return unavailable('shallow') if git('rev-parse', '--is-shallow-repository')&.strip == 'true'

      total = git('rev-list', '--count', 'HEAD')&.to_i
      return unavailable('unreadable') unless total&.positive?

      walk.merge(available: true, total_commits: total,
                 commits_last_365_days: git('rev-list', '--count', '--since=365.days.ago', 'HEAD').to_i,
                 contributors: git('log', '--format=%aE', 'HEAD').to_s.downcase.lines.uniq.size)
    end

    private

    def unavailable(reason)
      { available: false, reason: reason }
    end

    def git_present?
      !git('--version').nil?
    end

    def git(*args)
      output, status = Open3.capture2({ 'GIT_OPTIONAL_LOCKS' => '0' }, 'git', '-C', @root, *args, err: File::NULL)
      status.success? ? output : nil
    rescue SystemCallError
      nil
    end

    # Non-merge commits touching the application directory, newest first.
    def walk
      per_commit = []
      per_file = Hash.new(0)
      current = nil
      command = ['git', '-C', @root, 'log', '--no-merges', '--format=%x01', '--name-only', '--relative',
                 '-n', COMMIT_LIMIT.to_s, 'HEAD', '--', '.']
      IO.popen({ 'GIT_OPTIONAL_LOCKS' => '0' }, command, err: File::NULL) do |io|
        io.each_line do |line|
          line = line.chomp
          if line == SEPARATOR
            per_commit << current if current
            current = 0
          elsif !line.empty? && current
            current += 1
            per_file[line] += 1 if line.start_with?('app/')
          end
        end
      end
      per_commit << current if current
      { commits_walked: per_commit.size, walk_truncated: per_commit.size >= COMMIT_LIMIT,
        files_per_commit: Stats.dist(per_commit, histogram: true), app_files_touched: per_file.size,
        commits_per_app_file: Stats.dist(per_file.values, histogram: true) }
    end
  end

  # What the manifest and the generation marker record about the run.
  module RunFacts
    MODES = %w[full incremental refresh seed watch].freeze
    STATES = %w[available unavailable partial].freeze

    module_function

    def call(manifest, marker)
      timings = manifest['extractor_timings'].is_a?(Hash) ? manifest['extractor_timings'] : {}
      { woods_version: Privacy.version(manifest['woods_version']),
        extraction_mode: marker['reason'] ? Privacy.enum(marker['reason'], MODES) : 'unknown',
        generation: marker['number'].is_a?(Integer) ? marker['number'] : nil,
        total_units: integer(manifest['total_units']), total_chunks: integer(manifest['total_chunks']),
        units_by_directory: bucketed(manifest['counts']) { |value| integer(value) || 0 },
        extractor_timings: bucketed(timings) { |value| value.is_a?(Numeric) ? value.to_f : 0.0 }
          .transform_values { |seconds| seconds.round(3) },
        extractor_timings_total: timings.empty? ? nil : timings.values.grep(Numeric).sum.to_f.round(3),
        git_enrichment_state: enrichment(manifest['git_enrichment']) }
    end

    def integer(value)
      value.is_a?(Integer) ? value : nil
    end

    # Sum a directory-keyed table; keys outside Woods' directories go to "other".
    def bucketed(table)
      return {} unless table.is_a?(Hash)

      table.each_with_object(Hash.new(0)) do |(key, value), result|
        result[TYPE_DIRS.include?(key.to_s) ? key.to_s : OTHER] += yield(value)
      end
    end

    def enrichment(value)
      value.is_a?(Hash) && value['state'] ? Privacy.enum(value['state'], STATES) : 'unknown'
    end
  end

  # Collects every section.
  module Collector
    module_function

    def call(index_dir:, root:, timings:)
      source = IndexSource.new(index_dir)
      units = UnitFacts.new
      source.each_unit { |unit| units.add(unit) if unit.is_a?(Hash) }
      graph = source.artifact('dependency_graph.json')
      manifest = source.artifact('manifest.json')
      manifest = {} unless manifest.is_a?(Hash)
      models = units.models
      models[:concern_fan_in_top_10_all_units] = ConcernFanIn.top_10(graph)
      { profile_version: PROFILE_VERSION,
        index: units.index(source),
        graph: GraphFacts.new(graph, source.artifact('graph_analysis.json')).to_h,
        models: models,
        controllers: units.controllers(runtime_routes),
        files: FileFacts.new(root).to_h,
        app_weight: AppWeight.new(root, manifest, timings: timings).to_h,
        history: HistoryFacts.new(root).to_h,
        woods_run: RunFacts.call(manifest, source.marker) }
    ensure
      source&.close
    end

    def runtime_routes
      return nil unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

      Rails.application.routes.routes.size
    rescue StandardError
      nil
    end
  end

  # `--compare a.json b.json`: the ratios that drive extraction cost, larger gaps first.
  module Compare
    METRICS = [
      ['units', %w[index total_units]],
      ['edges per unit', %w[graph edges_per_node]],
      ['hub in-degree p99', %w[graph in_degree all p99]],
      ['hub in-degree max', %w[graph in_degree all max]],
      ['top-hub blast radius share', %w[graph top_hub_blast_radius transitive_share]],
      ['largest blast radius share (top 20)', %w[graph top_hub_blast_radius top_20_max_transitive_share]],
      ['model structural blast radius p50', %w[graph model_blast_radius structural_units p50]],
      ['model structural blast radius p90', %w[graph model_blast_radius structural_units p90]],
      ['model blast radius p50 (units)', %w[graph model_blast_radius units p50]],
      ['model blast radius p90 (units)', %w[graph model_blast_radius units p90]],
      ['cross-namespace edge share', %w[graph namespaces cross_namespace_edge_share]],
      ['top-level namespaces', %w[graph namespaces top_level_namespaces]],
      ['largest cycle (SCC) size', %w[graph cycles largest_component]],
      ['Ruby files', %w[files ruby all count]],
      ['Ruby file lines p99', %w[files ruby all lines p99]],
      ['model source lines p99', %w[index source_lines by_type model p99]],
      ['app callbacks per model p90', %w[models application_callbacks p90]],
      ['associations per model p90', %w[models associations p90]],
      ['top concern fan-in (models)', ['models', 'concern_fan_in_top_10', 0]],
      ['routes', %w[controllers routes_total_index]],
      ['gems in lockfile', %w[app_weight gems_in_lockfile]],
      ['boot seconds', %w[app_weight timings boot_seconds]],
      ['eager-load seconds', %w[app_weight timings eager_load_seconds]],
      ['commits', %w[history total_commits]]
    ].freeze

    module_function

    def call(path_a, path_b)
      a, b = [path_a, path_b].map { |path| JSON.parse(File.read(path, encoding: 'UTF-8')) }
      rows = METRICS.map { |label, path| row(label, dig(a, path), dig(b, path)) }
      rows = rows.sort_by.with_index { |entry, i| [entry[:gap] ? -entry[:gap] : Float::INFINITY, i] }
      lines = [format('%-36s %14s %14s %9s', 'metric (larger gaps first)', 'A', 'B', 'B / A')]
      rows.each do |entry|
        lines << format('%-36s %14s %14s %9s', entry[:label], show(entry[:a]), show(entry[:b]), entry[:ratio])
      end
      lines.join("\n")
    end

    def dig(document, path)
      value = path.reduce(document) do |node, key|
        node.is_a?(Hash) || (node.is_a?(Array) && key.is_a?(Integer)) ? node[key] : nil
      end
      value.is_a?(Numeric) ? value : nil
    end

    def row(label, left, right)
      return { label: label, a: left, b: right, ratio: 'n/a', gap: nil } unless left && right
      return { label: label, a: left, b: right, ratio: '1.00x', gap: 0.0 } if left == right
      return { label: label, a: left, b: right, ratio: 'inf', gap: Float::MAX } if left.zero? || right.zero?

      ratio = right.to_f / left
      { label: label, a: left, b: right, ratio: format('%.2fx', ratio), gap: Math.log(ratio).abs }
    end

    def show(value)
      case value
      when nil then '-'
      when Float then format('%.4g', value)
      else value.to_s
      end
    end
  end

  module_function

  def main(argv)
    options = { timings: false }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: bin/rails runner woods_shape_profile.rb [index_dir] [--out FILE] [--timings]'
      opts.on('--out FILE', 'write the profile to FILE instead of stdout') { |value| options[:out] = value }
      opts.on('--timings', 'boot the app twice in child processes to time boot and eager load') do
        options[:timings] = true
      end
      opts.on('--root DIR', 'application root (default: Rails.root, else the working directory)') do |value|
        options[:root] = value
      end
      opts.on('--compare', 'compare two profiles: --compare a.json b.json') { options[:compare] = true }
    end
    rest = parser.parse(argv)
    if options[:compare]
      abort parser.banner.sub(/\[index.*/, '--compare a.json b.json') unless rest.size == 2
      return puts(Compare.call(*rest))
    end

    rails_root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root&.to_s
    root = File.expand_path(options[:root] || rails_root || Dir.pwd)
    index_dir = File.expand_path(rest.first || 'tmp/woods', root)
    json = Privacy.seal(Collector.call(index_dir: index_dir, root: root, timings: options[:timings]))
    return puts(json) unless options[:out]

    File.write(options[:out], "#{json}\n")
    warn "woods_shape_profile: wrote #{options[:out]}"
  end
end

WoodsShapeProfile.main(ARGV) if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
