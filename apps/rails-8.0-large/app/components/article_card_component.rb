# ViewComponent — discovered from ViewComponent::Base.descendants at runtime.
class ArticleCardComponent < ViewComponent::Base
  def initialize(article:)
    @article = article
    super
  end

  def call
    content_tag(:article, @article.title, class: "article-card")
  end
end
