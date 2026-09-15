module Mutations
  class PublishArticle < GraphQL::Schema::Mutation
    argument :id, ID, required: true
    field :article, Types::ArticleType, null: true
    field :errors, [String], null: false
    def resolve(id:)
      article = Article.joins(:publication).where(publications: { organization_id: context[:organization].id }).find(id)
      article = ::PublishArticle.new(author: context[:author]).call(article)
      { article: article, errors: [] }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Pundit::NotAuthorizedError, EditorialWorkflow::InvalidTransition => e
      { article: nil, errors: [e.message] }
    end
  end
end
