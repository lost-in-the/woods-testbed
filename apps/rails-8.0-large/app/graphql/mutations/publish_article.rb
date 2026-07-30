module Mutations
  class PublishArticle < GraphQL::Schema::Mutation
    argument :title, String, required: true
    argument :body, String, required: false

    field :article, Types::ArticleType, null: true
    field :errors, [String], null: false

    def resolve(title:, body: nil)
      author = Author.first
      article = ::PublishArticle.new(author: author).call(title: title, body: body)
      { article: article, errors: [] }
    rescue ActiveRecord::RecordInvalid => e
      { article: nil, errors: e.record.errors.full_messages }
    end
  end
end
