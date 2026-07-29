module Resolvers
  class ArticlesResolver < GraphQL::Schema::Resolver
    type [Types::ArticleType], null: false

    argument :author_id, ID, required: false

    def resolve(author_id: nil)
      scope = Article.published.not_archived
      author_id ? scope.where(author_id: author_id) : scope
    end
  end
end
