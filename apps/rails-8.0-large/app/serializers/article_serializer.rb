class ArticleSerializer < ApplicationSerializer
  attributes :id, :title, :slug, :author_name, :published_at

  def id
    record.id
  end

  def title
    record.title
  end

  def slug
    record.slug
  end

  def author_name
    record.author&.display_name
  end

  def published_at
    record.published_at
  end
end
