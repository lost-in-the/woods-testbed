module Types
  class ArticleType < GraphQL::Schema::Object
    description "A published article"

    field :id, ID, null: false
    field :title, String, null: false
    field :slug, String, null: false
    field :published_at, GraphQL::Types::ISO8601DateTime, null: true
    field :comment_count, Integer, null: false

    def comment_count
      object.comments.size
    end
  end
end
