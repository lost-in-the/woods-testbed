# frozen_string_literal: true

# Extra audit fixtures are introduced only after the matched timing corpus has
# finished. The old baseline cannot publish the valid wrapped value classes.
module ReferenceDiscoveryCases
  VALUE_UNITS = {
    'ReferenceValueOwner::Criteria' => ['poro', 'app/models/reference_value_owner/criteria.rb'],
    'ReferenceValueOwner::Page' => ['poro', 'app/models/reference_value_owner/page.rb'],
    'ReferenceAssigned::Criteria' => ['poro', 'app/models/reference_assigned/criteria.rb'],
    'ReferenceAssigned::Page' => ['poro', 'app/models/reference_assigned/page.rb'],
    'ReferenceLibraryValues::Criteria' => ['lib', 'lib/reference_library_values/criteria.rb'],
    'ReferenceLibraryValues::Page' => ['lib', 'lib/reference_library_values/page.rb']
  }.freeze

  private

  def discovery_regressions!
    fixture = File.expand_path('../fixtures/discovery_regressions', __dir__)
    %w[app lib config].each { |name| FileUtils.cp_r(File.join(fixture, name, '.'), name) }
    check('real GraphQL fixtures boot and all three schemas answer their synthetic queries') do
      command(['bin/rails', 'runner', <<~RUBY])
        expected = { 'probe' => 'fixture-ok', 'rootProbe' => 'root-ok', 'spacedProbe' => 'spaced-ok' }
        result = ReferenceSchema.execute('{ probe rootProbe spacedProbe }').to_h
        raise result.inspect unless result == { 'data' => expected }
        [[ReferenceRuntimeSchemaA, 'first'], [ReferenceRuntimeSchemaB, 'second']].each do |schema, value|
          result = schema.execute('{ fixtureValue }').to_h
          raise result.inspect unless result == { 'data' => { 'fixtureValue' => value } }
        end
        raise 'schema fixture complexity not applied' unless ReferenceSchema.max_complexity == 123
      RUBY
    end
    check('full extraction publishes wrapped Struct/Data units without losing their parent') do
      operation('full')
      assert_value_units
      assert_owned_unit('poro', 'ReferenceValueOwner', 'app/models/reference_value_owner.rb')
      assert_missing('poro', 'ReferenceAssigned')
      assert_owned_unit('lib', 'ReferenceLibraryValues', 'lib/reference_library_values.rb')
    end
    check('all GraphQL schema/query/resolver units have working packaged lookup and schema source search') do
      assert_graphql_units
      lookup('graphql_type', 'ReferencePromotableType')
      assert_schema_search(123)
    end
    equivalence!('discovery fixture full extraction agrees with another independent full')
    assigned_value_transitions!
    graphql_discovery_transitions!
    check('combined discovery index validates and retains its original MCP reader') do
      command(['bin/rails', 'woods:validate'])
      raise 'reader replaced during discovery acceptance' unless @session.pid == @reader_pid
    end
  end

  def assert_owned_unit(type, identifier, path)
    unit = lookup(type, identifier)
    actual = unit.fetch('file_path').delete_prefix('/app/')
    raise "wrong source owner for #{identifier}: #{actual}" unless actual == path
    matching = units.select { |entry| entry['identifier'] == identifier && entry['type'] == type }
    raise "duplicate unit for #{type}:#{identifier}" unless matching.size == 1
    unit
  end

  def assert_value_units
    VALUE_UNITS.each do |identifier, (type, path)|
      assert_owned_unit(type, identifier, path)
      assert_edge('poro', 'ReferenceAssignedCaller', type, identifier, present: true)
    end
  end

  def assigned_value_transitions!
    path = VALUE_UNITS.fetch('ReferenceAssigned::Criteria').last
    original = File.binread(path)
    caller_digest = Digest::SHA256.file('app/models/reference_assigned_caller.rb').hexdigest
    ['class Criteria; attr_accessor :value; end', 'Criteria = Data.define(:value)',
     'Criteria = Struct.new(:value)'].each do |declaration|
      check("assigned child transition #{declaration} preserves identity and unchanged-caller references") do
        File.binwrite(path, original.sub('Criteria = Struct.new(:value)', declaration))
        operation('incremental', paths: [path])
        assert_value_units
        raise 'fixture caller changed' unless Digest::SHA256.file('app/models/reference_assigned_caller.rb').hexdigest == caller_digest
      end
      equivalence!("assigned child #{declaration} agrees with full extraction")
    end
    check('assigned target deletion removes its identity and unchanged-caller forward/reverse edge') do
      File.unlink(path)
      operation('incremental', paths: [path])
      assert_missing('poro', 'ReferenceAssigned::Criteria')
      assert_edge('poro', 'ReferenceAssignedCaller', 'poro', 'ReferenceAssigned::Criteria', present: false)
    end
    equivalence!('assigned target deletion agrees with full extraction')
    check('assigned target recreation and PORO/lib refresh restore exact source ownership') do
      File.binwrite(path, original)
      operation('incremental', paths: [path])
      operation('refresh', types: %w[poros libs])
      assert_value_units
    end
    equivalence!('assigned target recreation and refresh agree with full extraction')
  end

  def assert_graphql_units
    assert_owned_unit('graphql_type', 'ReferenceSchema', 'app/graphql/reference_schema.rb')
    assert_owned_unit('graphql_query', 'ReferenceQuery', 'app/graphql/reference_query.rb')
    %w[ReferenceAuthorizedResolver ReferenceChildResolver ReferenceRootResolver ReferenceSpacedResolver].each do |name|
      path = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      assert_owned_unit('graphql_resolver', name, "app/graphql/#{path}.rb")
    end
    %w[A B].each do |suffix|
      assert_owned_unit('graphql_type', "ReferenceRuntimeSchema#{suffix}", 'config/initializers/reference_runtime_schemas.rb')
      assert_owned_unit('graphql_query', "ReferenceRuntimeQuery#{suffix}", 'config/initializers/reference_runtime_schemas.rb')
    end
  end

  def assert_schema_search(value)
    unit = lookup('graphql_type', 'ReferenceSchema')
    raise 'schema kind missing' unless unit.dig('metadata', 'graphql_kind') == 'schema'
    query = "max_complexity #{value}"
    raise 'schema source configuration absent' unless unit.fetch('source_code').include?(query)
    result = @session.call_tool('search', { query: query, fields: ['source_code'], limit: 100 })
    rows = result.fetch('structuredContent').fetch('data').fetch('results')
    raise 'schema source missing from packaged MCP search' unless rows.any? { |row| row['identifier'] == 'ReferenceSchema' }
  end

  def graphql_discovery_transitions!
    schema_path = 'app/graphql/reference_schema.rb'
    check('incremental schema edit publishes real configuration through the held reader') do
      File.write(schema_path, File.read(schema_path).sub('max_complexity 123', 'max_complexity 234'))
      operation('incremental', paths: [schema_path])
      assert_schema_search(234)
    end
    equivalence!('schema configuration edit agrees with full extraction')
    child_path = 'app/graphql/reference_child_resolver.rb'
    check('equivalent superclass spelling preserves a loaded inherited resolver') do
      File.write(child_path, File.read(child_path).sub('< ReferenceAuthorizedResolver', '<  ::ReferenceAuthorizedResolver'))
      operation('incremental', paths: [child_path])
      assert_owned_unit('graphql_resolver', 'ReferenceChildResolver', child_path)
    end
    equivalence!('resolver source-format edit agrees with full extraction')
    check('new schema promotes an existing object to query root without duplicate typed identities') do
      path = 'app/graphql/reference_promoting_schema.rb'
      File.write(path, "class ReferencePromotingSchema < GraphQL::Schema\n  query ReferencePromotableType\nend\n")
      operation('incremental', paths: [path])
      lookup('graphql_type', 'ReferencePromotingSchema')
      lookup('graphql_query', 'ReferencePromotableType')
      assert_missing('graphql_type', 'ReferencePromotableType')
      matches = units.select { |unit| unit['identifier'] == 'ReferencePromotableType' }
      raise 'old query-root type survived' unless matches.map { |unit| unit['type'] } == ['graphql_query']
    end
    equivalence!('query-root promotion agrees with full extraction')
    check('targeted GraphQL refresh retains every schema inventory and resolver') do
      operation('refresh', types: ['graphql'])
      assert_graphql_units
      assert_schema_search(234)
      lookup('graphql_query', 'ReferencePromotableType')
    end
    equivalence!('GraphQL refresh agrees with full extraction')
  end
end
