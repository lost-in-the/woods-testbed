# frozen_string_literal: true

ReferenceRuntimeQueryA = Class.new(GraphQL::Schema::Object) do
  graphql_name "ReferenceRuntimeQueryA"
  field :fixture_value, String, null: false
  def fixture_value
    "first"
  end
end
ReferenceRuntimeSchemaA = Class.new(GraphQL::Schema) do
  query ReferenceRuntimeQueryA
end
ReferenceRuntimeQueryB = Class.new(GraphQL::Schema::Object) do
  graphql_name "ReferenceRuntimeQueryB"
  field :fixture_value, String, null: false
  def fixture_value
    "second"
  end
end
ReferenceRuntimeSchemaB = Class.new(GraphQL::Schema) do
  query ReferenceRuntimeQueryB
end
