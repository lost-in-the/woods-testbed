# app/decorators is scanned by BOTH DecoratorExtractor and SerializerExtractor,
# so this file legitimately produces a decorator unit; the serializer exemplar
# lives in app/serializers to keep the two types distinguishable.
class ArticleDecorator
  def initialize(article)
    @article = article
  end

  def title
    @article.title.to_s.upcase
  end

  def summary
    @article.body.to_s.truncate(80)
  end
end
