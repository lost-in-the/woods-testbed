module Resolvers
  class ArticlesResolver < GraphQL::Schema::Resolver
    type [Types::ArticleType], null: false
    def resolve
      return [] unless context[:author] && context[:organization]
      scope = Article.joins(:publication).where(publications: { organization_id: context[:organization].id })
      scope = scope.where(author: context[:author]).or(scope.where(state: 'published')) unless context[:author].editor_of?(context[:organization])
      scope.order(id: :desc).limit(25)
    end
  end
end
