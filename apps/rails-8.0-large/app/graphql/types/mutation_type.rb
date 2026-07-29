module Types
  class MutationType < GraphQL::Schema::Object
    field :publish_article, mutation: Mutations::PublishArticle
  end
end
