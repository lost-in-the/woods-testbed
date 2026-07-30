module Types
  class QueryType < GraphQL::Schema::Object
    field :articles, resolver: Resolvers::ArticlesResolver
  end
end
